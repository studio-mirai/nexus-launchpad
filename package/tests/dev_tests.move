#[test_only]
module nexus_launchpad::dev_tests;

use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    kiosk::{Self},
    package::{Publisher},
    random::{Self, Random},
    sui::SUI,
    test_scenario::{Self as scen, Scenario},
    test_utils::{destroy},
};
use nexus_launchpad::{
    dev_nft::{Self, DevNft},
    dev_setup::{dev_setup},
    launch::{Self, Launch},
    phase::{Phase},
    mint::{Self},
    whitelist::{Whitelist},
};

// === addresses ===

const ADMIN: address = @0xaa1;
const ONE_HOUR: u64 = 1 * 60 * 60 * 1000;

// === test runner ===

public struct TestRunner {
    scen: Scenario,
    clock: Clock,
    random: Random,
    publisher: Publisher,
}

fun begin(
    sender: address,
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
    scen.next_tx(sender);
    dev_nft::init_for_testing(scen.ctx());
    scen.next_tx(sender);
    let publisher = scen.take_from_sender<Publisher>();

    TestRunner { scen, clock, random, publisher }
}

// === helpers for sui modules ===

public fun send_sui(
    runner: &mut TestRunner,
    value: u64,
): Coin<SUI> {
    return coin::mint_for_testing<SUI>(value, runner.scen.ctx())
}

// === tests ===

#[test]
fun test_kiosk_none()
{
    let mut runner = begin(ADMIN);

    dev_setup(
        &runner.publisher,
        1_000_000_000, // item_price_sui
        15, // launch_total_supply
        5, // phase_max_mint_allocation
        10, // phase_max_mint_count
        true, // phase_allow_bulk_mint
        0, // wl_amount
        launch::new_kiosk_requirement_none(),
        &runner.clock,
        runner.scen.ctx(),
    );

    runner.scen.next_tx(ADMIN);
    runner.clock.increment_for_testing(ONE_HOUR);

    let mut launch: Launch<DevNft> = runner.scen.take_shared();
    let mut phase: Phase<DevNft> = runner.scen.take_shared();
    let mut pay_coin = runner.send_sui(3_000_000_000);

    mint::mint(
        &mut launch,
        &mut phase,
        3,
        &mut pay_coin,
        &runner.random,
        &runner.clock,
        runner.scen.ctx()
    );
    pay_coin.destroy_zero();

    destroy(launch);
    destroy(phase);
    destroy(runner);
}

#[test]
fun test_kiosk_place()
{
    let mut runner = begin(ADMIN);

    dev_setup(
        &runner.publisher,
        1_000_000_000, // item_price_sui
        15, // launch_total_supply
        5, // phase_max_mint_allocation
        10, // phase_max_mint_count
        true, // phase_allow_bulk_mint
        0, // wl_amount
        launch::new_kiosk_requirement_place(),
        &runner.clock,
        runner.scen.ctx(),
    );

    runner.scen.next_tx(ADMIN);
    runner.clock.increment_for_testing(ONE_HOUR);

    let mut launch: Launch<DevNft> = runner.scen.take_shared();
    let mut phase: Phase<DevNft> = runner.scen.take_shared();
    let mut pay_coin = runner.send_sui(3_000_000_000);

    let (mut kiosk, kiosk_cap) = kiosk::new(runner.scen.ctx());

    mint::mint_and_place(
        &mut launch,
        &mut phase,
        3,
        &mut pay_coin,
        &mut kiosk,
        &kiosk_cap,
        &runner.random,
        &runner.clock,
        runner.scen.ctx()
    );
    pay_coin.destroy_zero();

    destroy(launch);
    destroy(phase);
    destroy(kiosk);
    destroy(kiosk_cap);
    destroy(runner);
}

#[test]
fun test_kiosk_none_wl()
{
    let mut runner = begin(ADMIN);

    dev_setup(
        &runner.publisher,
        1_000_000_000, // item_price_sui
        15, // launch_total_supply
        5, // phase_max_mint_allocation
        10, // phase_max_mint_count
        true, // phase_allow_bulk_mint
        3, // wl_amount
        launch::new_kiosk_requirement_none(),
        &runner.clock,
        runner.scen.ctx(),
    );

    runner.scen.next_tx(ADMIN);
    runner.clock.increment_for_testing(ONE_HOUR);

    let mut launch: Launch<DevNft> = runner.scen.take_shared();
    let mut phase: Phase<DevNft> = runner.scen.take_shared();
    let mut pay_coin = runner.send_sui(3_000_000_000);

    let wl1 = runner.scen.take_from_sender<Whitelist>();
    let wl2 = runner.scen.take_from_sender<Whitelist>();
    let wl3 = runner.scen.take_from_sender<Whitelist>();

    mint::wl_mint(
        &mut launch,
        &mut phase,
        3,
        &mut pay_coin,
        vector[wl1, wl2, wl3],
        &runner.random,
        &runner.clock,
        runner.scen.ctx()
    );
    pay_coin.destroy_zero();
    destroy(launch);
    destroy(phase);
    destroy(runner);
}
