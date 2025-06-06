#[test_only]
module nexus_launchpad::tests;

// === imports ===

use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    kiosk::{Kiosk, KioskOwnerCap},
    package::{Publisher},
    random::{Self, Random},
    sui::{SUI},
    test_scenario::{Self as scen, Scenario},
    test_utils::{assert_eq, destroy},
};

use nexus_launchpad::{
    dev_nft::{Self, DevNft},
    launch::{Self, Launch, LaunchAdminCap, LaunchOperatorCap, KioskRequirement},
    phase::{Self, Phase, PhaseKind, RegisterPhasePromise},
    mint::{Self},
    whitelist::{Self, Whitelist},
};

// === constants ===

const ADMIN: address = @0xaa1;
const USER_1: address = @0xbb1;
const USER_2: address = @0xbb2;
const USER_3: address = @0xbb3;
const ONE_HOUR: u64 = 1 * 60 * 60 * 1000;

// default values
const LAUNCH_SUPPLY: u64 = 15;
const PHASE_MAX_ALLO: u64 = 5; // per user
const PHASE_MAX_COUNT: u64 = 10; // per phase
const PHASE_ALLOW_BULK: bool = true;
const PHASE_START_TS: u64 = 1; // 1 millisecond from now
const PHASE_END_TS: u64 = 7 * 24 * 60 * 60 * 1000; // 1 week from now
const ITEM_PRICE: u64 = 1_000_000_000; // 1 SUI
const ITEM_AMOUNT: u64 = 3; // quantity of items to mint

// === runner ===

public struct TestRunner {
    scen: Scenario,
    clock: Clock,
    random: Random,
    publisher: Publisher,
    launch: Launch<DevNft>,
    launch_admin_cap: LaunchAdminCap,
    launch_operator_cap: LaunchOperatorCap,
}

/// create a Launch in the SUPPLYING state
fun begin(
    launch_total_supply: u64,
    kiosk_req: launch::KioskRequirement,
): TestRunner
{
    // random
    let mut scen = scen::begin(@0x0);
    random::create_for_testing(scen.ctx());
    scen.next_tx(@0x0);
    let random: Random = scen.take_shared();

    // clock
    let mut clock = clock::create_for_testing(scen.ctx());
    clock.set_for_testing(ONE_HOUR);

    // dev_nft
    scen.next_tx(ADMIN);
    dev_nft::init_for_testing(scen.ctx());
    scen.next_tx(ADMIN);
    let publisher = scen.take_from_sender<Publisher>();

    // launch
    let (
        mut launch,
        launch_admin_cap,
        share_promise,
    ) = launch::new<DevNft>(
        &publisher,
        launch_total_supply,
        kiosk_req,
        scen.ctx(),
    );
    destroy(share_promise);

    launch.add_operator(&launch_admin_cap, ADMIN);
    let launch_operator_cap = launch.request_operator_cap(scen.ctx());

    return TestRunner {
        scen,
        clock,
        random,
        publisher,
        launch,
        launch_admin_cap,
        launch_operator_cap,
    }
}

/// create a Launch, add items to it, schedule a Phase, set LaunchState::ACTIVE
fun begin_with_phase(
    kiosk_req: KioskRequirement,
    phase_kind: PhaseKind,
): TestRunner
{
    // LaunchState::SUPPLYING

    let mut runner = begin(LAUNCH_SUPPLY, kiosk_req);
    runner.launch__add_items(LAUNCH_SUPPLY);

    // LaunchState::ACTIVE

    runner.launch__set_active_state();

    // PhaseState::CREATED

    let (mut phase, schedule_promise) = runner.phase__new__default(phase_kind);
    runner.phase__add_payment_type<SUI>(&mut phase, ITEM_PRICE);

    // PhaseState::ACTIVE
    phase.register(
        schedule_promise,
        &runner.launch_operator_cap,
        &mut runner.launch,
    );

    return runner
}

// === helpers for launchpad package ===
//
// These helpers wrap the launchpad functions and are named following this convention:
// <module>__<function>__[variant]
//
// For example:
// `runner.launch__add_items;` calls `launch::add_items()`.
// `runner.phase__new__default;` calls `phase::new()` using default values.

fun launch__add_items(
    runner: &mut TestRunner,
    count: u64,
) {
    let items = vector::tabulate!(
        count,
        |i| dev_nft::new_dev_nft(
            b"Demo NFT",
            i + 1,
            b"https://images.stockcake.com/public/a/8/e/a8e29d30-9da7-418b-932b-c12c3260c2ef_medium/abstract-geometric-design-stockcake.jpg",
            runner.scen.ctx(),
        )
    );
    runner.launch.add_items(&runner.launch_operator_cap, items);
}

fun launch__set_active_state(
    runner: &mut TestRunner,
) {
    runner.launch.set_active_state(&runner.launch_operator_cap);
}

fun phase__new__default(
    runner: &mut TestRunner,
    kind: PhaseKind,
): (Phase<DevNft>, RegisterPhasePromise) {
    let clock = &runner.clock;
    let now = clock.timestamp_ms();
    let (phase, schedule_promise) = phase::new<DevNft>(
        &runner.launch_operator_cap,
        &runner.launch,
        kind,
        option::some(b"Phase Name".to_string()),
        option::some(b"Phase Description".to_string()),
        now + PHASE_START_TS,
        now + PHASE_END_TS,
        PHASE_MAX_ALLO,
        PHASE_MAX_COUNT,
        PHASE_ALLOW_BULK,
        clock,
        runner.scen.ctx(),
    );
    runner.clock.increment_for_testing(PHASE_START_TS);
    return (phase, schedule_promise)
}

fun phase__add_payment_type<C>(
    runner: &TestRunner,
    phase: &mut Phase<DevNft>,
    price: u64,
) {
    phase.add_payment_type<DevNft, C>(&runner.launch_operator_cap, price);
}

fun whitelist__new(
    runner: &mut TestRunner,
    sender: address,
    count: u64,
): vector<Whitelist>
{
    runner.scen.next_tx(sender);
    let mut phase: Phase<DevNft> = runner.scen.take_shared();
    let wls = vector::tabulate!(
        count,
        |_| whitelist::new<DevNft>(
            &runner.launch_operator_cap, &mut runner.launch, &mut phase, runner.scen.ctx(),
        )
    );
    scen::return_shared(phase);
    return wls
}

fun mint__mint(
    runner: &mut TestRunner,
    phase: &mut Phase<DevNft>,
    quantity: u64,
    pay_coin: &mut Coin<SUI>,
) {
    let random = &runner.random;
    let clock = &runner.clock;
    mint::mint(
        &mut runner.launch,
        phase,
        quantity,
        pay_coin,
        random,
        clock,
        runner.scen.ctx(),
    );
}

fun mint__wl_mint(
    runner: &mut TestRunner,
    phase: &mut Phase<DevNft>,
    quantity: u64,
    pay_coin: &mut Coin<SUI>,
    whitelists: vector<Whitelist>,
) {
    mint::wl_mint(
        &mut runner.launch,
        phase,
        quantity,
        pay_coin,
        whitelists,
        &runner.random,
        &runner.clock,
        runner.scen.ctx(),
    );
}

fun mint__mint__with_new_sui(
    runner: &mut TestRunner,
    sender: address,
    quantity: u64,
    item_price: u64,
) {
    runner.scen.next_tx(sender);
    let mut phase: Phase<DevNft> = runner.scen.take_shared();
    let mut pay_coin = runner.mint_coin<SUI>(quantity * item_price);
    runner.mint__mint(&mut phase, quantity, &mut pay_coin);
    transfer::public_transfer(pay_coin, sender);

    scen::return_shared(phase);
    runner.scen.next_tx(sender);
}

fun mint__wl_mint__with_new_sui(
    runner: &mut TestRunner,
    sender: address,
    quantity: u64,
    item_price: u64,
    wls: vector<Whitelist>,
) {
    runner.scen.next_tx(sender);
    let mut phase: Phase<DevNft> = runner.scen.take_shared();
    let mut pay_coin = runner.mint_coin<SUI>(quantity * item_price);
    runner.mint__wl_mint(&mut phase, quantity, &mut pay_coin, wls);
    transfer::public_transfer(pay_coin, sender);

    scen::return_shared(phase);
    runner.scen.next_tx(sender);
}

fun mint__mint_and_place(
    runner: &mut TestRunner,
    phase: &mut Phase<DevNft>,
    quantity: u64,
    pay_coin: &mut Coin<SUI>,
) {
    let random = &runner.random;
    let clock = &runner.clock;
    mint::mint_and_place_in_new_kiosk(
        &mut runner.launch,
        phase,
        quantity,
        pay_coin,
        random,
        clock,
        runner.scen.ctx()
    );
}

fun mint__mint_and_place__with_new_sui(
    runner: &mut TestRunner,
    sender: address,
    quantity: u64,
    item_price: u64,
) {
    runner.scen.next_tx(sender);
    let mut phase: Phase<DevNft> = runner.scen.take_shared();
    let mut pay_coin = runner.mint_coin<SUI>(quantity * item_price);
    runner.mint__mint_and_place(&mut phase, quantity, &mut pay_coin);
    transfer::public_transfer(pay_coin, sender);

    scen::return_shared(phase);
    runner.scen.next_tx(sender);
}

// === tests ===

// === tests: mint: basic ===

#[test]
fun test_mint_ok_kiosk_none()
{
    let mut runner = begin_with_phase(
        launch::new_kiosk_requirement_none(),
        phase::new_phase_kind_public(),
    );

    runner.clock.increment_for_testing(ONE_HOUR);

    runner.mint__mint__with_new_sui(USER_1, ITEM_AMOUNT, ITEM_PRICE);

    runner.assert_owns_nfts(USER_1, ITEM_AMOUNT);

    destroy(runner);
}

#[test]
fun test_mint_ok_kiosk_none_wl()
{
    let mut runner = begin_with_phase(
        launch::new_kiosk_requirement_none(),
        phase::new_phase_kind_whitelist(),
    );

    runner.clock.increment_for_testing(ONE_HOUR);

    let wls = runner.whitelist__new(USER_1, ITEM_AMOUNT);
    runner.mint__wl_mint__with_new_sui(USER_1, ITEM_AMOUNT, ITEM_PRICE, wls);

    runner.assert_owns_nfts(USER_1, ITEM_AMOUNT);

    destroy(runner);
}

#[test]
fun test_mint_ok_kiosk_place()
{
    let mut runner = begin_with_phase(
        launch::new_kiosk_requirement_place(),
        phase::new_phase_kind_public(),
    );

    runner.clock.increment_for_testing(ONE_HOUR);

    runner.mint__mint_and_place__with_new_sui(USER_1, ITEM_AMOUNT, ITEM_PRICE);

    let kiosk = runner.scen.take_shared<Kiosk>();
    assert_eq(ITEM_AMOUNT, kiosk.item_count() as u64);

    let cap = runner.scen.take_from_sender<KioskOwnerCap>();
    assert_eq(object::id(&kiosk), cap.kiosk());

    destroy(kiosk);
    destroy(cap);
    destroy(runner);
}

// === tests: mint: various ===

// #[test]
// fun test_mint_ok_above_max_mint_allocation() // TODO: no longer allowed, test for error
// {
//     let mut runner = begin_with_phase(
//         launch::new_kiosk_requirement_none(),
//         phase::new_phase_kind_public(),
//     );

//     runner.clock.increment_for_testing(ONE_HOUR);

//     // try to mint more than max individual allocation
//     runner.mint__mint__with_new_sui(USER_1, PHASE_MAX_ALLO + 1, ITEM_PRICE);

//     // user should only receive the max individual allocation
//     runner.assert_owns_nfts(USER_1, PHASE_MAX_ALLO);

//     // TODO check refund

//     destroy(runner);
// }

// #[test]
// fun test_mint_ok_payment_refund() // TODO: no longer allowed, test for error
// {
//     let mut runner = begin_with_phase(
//         launch::new_kiosk_requirement_none(),
//         phase::new_phase_kind_public(),
//     );

//     runner.clock.increment_for_testing(ONE_HOUR);

//     // user will request this many more items than allowed
//     let excess_quantity = 3;
//     runner.mint__mint__with_new_sui(
//         USER_1,
//         PHASE_MAX_ALLO + excess_quantity,
//         ITEM_PRICE,
//     );

//     runner.assert_owns_sui(USER_1, ITEM_PRICE * excess_quantity);

//     destroy(runner);
// }

// === tests: mint: errors ===

// #[test, expected_failure(abort_code = phase::EPhaseNotMintable)]
// fun test_mint_e_phase_not_started() // TODO
// {
//     let mut runner = begin_with_phase(
//         launch::new_kiosk_requirement_none(),
//         phase::new_phase_kind_public(),
//     );

//     // runner.clock.increment_for_testing(ONE_HOUR);

//     runner.mint__mint__with_new_sui(USER_1, ITEM_AMOUNT, ITEM_PRICE);

//     destroy(runner);
// }

#[test, expected_failure(abort_code = phase::EPhaseNotMintableTimeRange)]
fun test_mint_e_phase_not_mintable_time_range()
{
    let mut runner = begin_with_phase(
        launch::new_kiosk_requirement_none(),
        phase::new_phase_kind_public(),
    );

    runner.clock.increment_for_testing(PHASE_END_TS);

    runner.mint__mint__with_new_sui(USER_1, ITEM_AMOUNT, ITEM_PRICE);

    destroy(runner);
}

#[test, expected_failure(abort_code = phase::EPhaseNoRemainingMints)]
fun test_mint_e_phase_no_remaining_mints()
{
    let mut runner = begin_with_phase(
        launch::new_kiosk_requirement_none(),
        phase::new_phase_kind_public(),
    );

    runner.clock.increment_for_testing(ONE_HOUR);

    // mint PHASE_MAX_COUNT (5 + 5 = 10)
    vector[USER_1, USER_2].do!(|sender| {
        runner.mint__mint__with_new_sui(
            sender,
            PHASE_MAX_ALLO,
            ITEM_PRICE,
        );
        runner.assert_owns_nfts(sender, PHASE_MAX_ALLO);
    });

    // try (and fail) to mint 1 more item
    runner.mint__mint__with_new_sui(USER_3, 1, ITEM_PRICE);

    destroy(runner);
}

#[test, expected_failure(abort_code = mint::EIncorrectPaymentAmount)]
fun test_mint_e_incorrect_payment_amount()
{
    let mut runner = begin_with_phase(
        launch::new_kiosk_requirement_none(),
        phase::new_phase_kind_public(),
    );

    runner.clock.increment_for_testing(ONE_HOUR);

    runner.mint__mint__with_new_sui(
        USER_1,
        1,
        ITEM_PRICE - 1, // try to pay less than the item price
    );

    destroy(runner);
}

#[test, expected_failure(abort_code = mint::EIncorrectWhitelistCount)]
fun test_mint_e_incorrect_whitelist_count()
{
    let mut runner = begin_with_phase(
        launch::new_kiosk_requirement_none(),
        phase::new_phase_kind_whitelist(),
    );

    runner.clock.increment_for_testing(ONE_HOUR);

    // try to mint with fewer whitelist tickets than requested quantity
    let wls = runner.whitelist__new(USER_1, ITEM_AMOUNT - 1);
    runner.mint__wl_mint__with_new_sui(USER_1, ITEM_AMOUNT, ITEM_PRICE, wls);

    destroy(runner);
}

#[test, expected_failure(abort_code = mint::EIncorrectWhitelistForPhase)]
fun test_mint_e_incorrect_whitelist_for_phase()
{
    // LaunchState::SUPPLYING

    let mut runner = begin(LAUNCH_SUPPLY, launch::new_kiosk_requirement_none());
    runner.launch__add_items(LAUNCH_SUPPLY);
    runner.launch__set_active_state();

    // PhaseState::CREATED

    let (mut phase1, promise1) = runner.phase__new__default(phase::new_phase_kind_whitelist());
    let phase1_id = object::id(&phase1);
    runner.phase__add_payment_type<SUI>(&mut phase1, ITEM_PRICE);

    let (mut phase2, promise2) = runner.phase__new__default(phase::new_phase_kind_whitelist());
    let phase2_id = object::id(&phase2);
    runner.phase__add_payment_type<SUI>(&mut phase2, ITEM_PRICE);

    // PhaseState::ACTIVE

    phase1.register(
        promise1,
        &runner.launch_operator_cap,
        &mut runner.launch,
    );
    phase2.register(
        promise2,
        &runner.launch_operator_cap,
        &mut runner.launch,
    );

    runner.clock.increment_for_testing(35 * ONE_HOUR); // middle of phase2
    // let cap = &runner.launch_operator_cap;
    // let clock = &runner.clock;
    // launch::advance_phase(&mut runner.launch, cap, clock); // move to phase 2

    runner.scen.next_tx(USER_1);

    // create a whitelist for phase1
    let mut phase1 = runner.scen.take_shared_by_id<Phase<DevNft>>(phase1_id);
    let wl1 = whitelist::new<DevNft>(
        &runner.launch_operator_cap,
        &mut runner.launch,
        &mut phase1,
        runner.scen.ctx(),
    );
    scen::return_shared(phase1);

    // try to use whitelist from phase1 in phase2
    let mut phase2 = runner.scen.take_shared_by_id<Phase<DevNft>>(phase2_id);
    let mut pay_coin = runner.mint_coin<SUI>(ITEM_PRICE);
    runner.mint__wl_mint(&mut phase2, 1, &mut pay_coin, vector[wl1]);
    transfer::public_transfer(pay_coin, USER_1);

    destroy(phase2);
    destroy(runner);
}

// === tests: phase: errors ===

#[test, expected_failure(abort_code = phase::EPhaseMaxCountExceedsLaunchSupply)]
fun test_schedule_e_phase_max_count_exceeds_launch_supply()
{
    // LaunchState::SUPPLYING

    let mut runner = begin(LAUNCH_SUPPLY, launch::new_kiosk_requirement_none());
    runner.launch__add_items(LAUNCH_SUPPLY);
    runner.launch__set_active_state();

    // PhaseState::CREATED

    let clock = &runner.clock;
    let (mut phase, schedule_promise) = phase::new<DevNft>(
        &runner.launch_operator_cap,
        &runner.launch,
        phase::new_phase_kind_public(),
        option::some(b"Phase Name".to_string()),
        option::some(b"Phase Description".to_string()),
        clock.timestamp_ms() + PHASE_START_TS,
        clock.timestamp_ms() + PHASE_END_TS,
        PHASE_MAX_ALLO,
        // try to create a phase with more items than the total launch supply
        LAUNCH_SUPPLY + 1,
        PHASE_ALLOW_BULK,
        clock,
        runner.scen.ctx(),
    );

    runner.phase__add_payment_type<SUI>(&mut phase, ITEM_PRICE);

    // LaunchState::ACTIVE

    // should not be allowed to schedule this phase
    phase.register(
        schedule_promise,
        &runner.launch_operator_cap,
        &mut runner.launch,
    );

    destroy(runner);
}

// === helpers for sui modules ===

fun mint_coin<C>(
    runner: &mut TestRunner,
    value: u64,
): Coin<C> {
    return coin::mint_for_testing<C>(value, runner.scen.ctx())
}

fun assert_owns_nfts(
    runner: &mut TestRunner,
    sender: address,
    expected_quantity: u64,
) {
    runner.scen.next_tx(sender);
    let nft_ids = runner.scen.ids_for_sender<DevNft>();
    assert_eq(expected_quantity, nft_ids.length());
}

public fun assert_owns_sui(
    runner: &mut TestRunner,
    owner: address,
    sui_value: u64,
) {
    runner.scen.next_tx(owner);
    let coin = runner.scen.take_from_sender<Coin<SUI>>();
    assert_eq( coin.value(), sui_value );
    transfer::public_transfer(coin, owner);
}
