module nexus_launchpad::mint;

use nexus_launchpad::launch::Launch;
use nexus_launchpad::phase::Phase;
use nexus_launchpad::whitelist::Whitelist;
use std::type_name::{Self, TypeName};
use sui::clock::Clock;
use sui::coin::Coin;
use sui::event::emit;
use sui::kiosk::{Self, Kiosk, KioskOwnerCap};
use sui::random::Random;
use sui::transfer_policy::TransferPolicy;

//=== Events ===

public struct ItemMintedEvent has copy, drop {
    launch_id: ID,
    phase_id: ID,
    item_id: ID,
    minted_by: address,
    payment_type: TypeName,
    payment_value: u64,
}

//=== Errors ===

const EIncorrectPaymentAmount: u64 = 30001;
const EIncorrectWhitelistCount: u64 = 30002;
const EIncorrectWhitelistForPhase: u64 = 30003;
const EPhaseMaxMintCountExceeded: u64 = 30004;
const EBulkMintNotAllowed: u64 = 30005;
const EParticipantMintCountExceeded: u64 = 30006;

//=== Public Functions ===

entry fun mint<T: key + store, C>(
    launch: &mut Launch<T>,
    phase: &mut Phase<T>,
    quantity: u64,
    payment: &mut Coin<C>,
    random: &Random,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Assert the Launch does not require a Kiosk.
    launch.assert_kiosk_requirement_none();
    // Assert the Phase is public.
    phase.assert_is_public();

    let items = internal_mint(
        launch,
        phase,
        quantity,
        payment,
        random,
        clock,
        ctx,
    );

    items.destroy!(|item| transfer::public_transfer(item, ctx.sender()));
}

entry fun wl_mint<T: key + store, C>(
    launch: &mut Launch<T>,
    phase: &mut Phase<T>,
    quantity: u64,
    payment: &mut Coin<C>,
    whitelists: vector<Whitelist>,
    random: &Random,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Assert the Launch does not require a Kiosk.
    launch.assert_kiosk_requirement_none();
    // Assert the Phase is whitelist.
    phase.assert_is_whitelist();

    let items = internal_mint(
        launch,
        phase,
        quantity,
        payment,
        random,
        clock,
        ctx,
    );

    internal_process_whitelists(whitelists, phase, items.length(), ctx);

    items.destroy!(|item| transfer::public_transfer(item, ctx.sender()));
}

entry fun mint_and_lock<T: key + store, C>(
    launch: &mut Launch<T>,
    phase: &mut Phase<T>,
    quantity: u64,
    payment: &mut Coin<C>,
    kiosk: &mut Kiosk,
    kiosk_owner_cap: &KioskOwnerCap,
    policy: &TransferPolicy<T>,
    random: &Random,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Assert the Launch requires a Kiosk.
    launch.assert_kiosk_requirement_lock();
    // Assert the Phase is public.
    phase.assert_is_public();

    let items = internal_mint(
        launch,
        phase,
        quantity,
        payment,
        random,
        clock,
        ctx,
    );

    items.destroy!(|item| kiosk.lock(kiosk_owner_cap, policy, item));
}

entry fun wl_mint_and_lock<T: key + store, C>(
    launch: &mut Launch<T>,
    phase: &mut Phase<T>,
    quantity: u64,
    payment: &mut Coin<C>,
    whitelists: vector<Whitelist>,
    kiosk: &mut Kiosk,
    kiosk_owner_cap: &KioskOwnerCap,
    policy: &TransferPolicy<T>,
    random: &Random,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Assert the Launch requires a Kiosk with lock policy.
    launch.assert_kiosk_requirement_lock();
    // Assert the Phase is whitelist.
    phase.assert_is_whitelist();

    launch.assert_kiosk_requirement_lock();

    let items = internal_mint(
        launch,
        phase,
        quantity,
        payment,
        random,
        clock,
        ctx,
    );

    internal_process_whitelists(whitelists, phase, items.length(), ctx);

    items.destroy!(|item| kiosk.lock(kiosk_owner_cap, policy, item));
}

entry fun mint_and_lock_in_new_kiosk<T: key + store, C>(
    launch: &mut Launch<T>,
    phase: &mut Phase<T>,
    quantity: u64,
    payment: &mut Coin<C>,
    policy: &TransferPolicy<T>,
    random: &Random,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Assert the Launch requires a Kiosk.
    launch.assert_kiosk_requirement_lock();
    // Assert the Phase is public.
    phase.assert_is_public();

    let (mut kiosk, kiosk_owner_cap) = kiosk::new(ctx);

    let items = internal_mint(
        launch,
        phase,
        quantity,
        payment,
        random,
        clock,
        ctx,
    );

    items.destroy!(
        |item| kiosk.lock(
            &kiosk_owner_cap,
            policy,
            item,
        ),
    );

    transfer::public_share_object(kiosk);
    transfer::public_transfer(kiosk_owner_cap, ctx.sender());
}

entry fun wl_mint_and_lock_in_new_kiosk<T: key + store, C>(
    launch: &mut Launch<T>,
    phase: &mut Phase<T>,
    quantity: u64,
    payment: &mut Coin<C>,
    whitelists: vector<Whitelist>,
    policy: &TransferPolicy<T>,
    random: &Random,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Assert the Launch requires a Kiosk with lock policy.
    launch.assert_kiosk_requirement_lock();
    // Assert the Phase is whitelist.
    phase.assert_is_whitelist();

    launch.assert_kiosk_requirement_lock();

    let (mut kiosk, kiosk_owner_cap) = kiosk::new(ctx);

    let items = internal_mint(
        launch,
        phase,
        quantity,
        payment,
        random,
        clock,
        ctx,
    );

    internal_process_whitelists(whitelists, phase, items.length(), ctx);

    items.destroy!(
        |item| kiosk.lock(
            &kiosk_owner_cap,
            policy,
            item,
        ),
    );

    transfer::public_share_object(kiosk);
    transfer::public_transfer(kiosk_owner_cap, ctx.sender());
}

entry fun mint_and_place<T: key + store, C>(
    launch: &mut Launch<T>,
    phase: &mut Phase<T>,
    quantity: u64,
    payment: &mut Coin<C>,
    kiosk: &mut Kiosk,
    kiosk_owner_cap: &KioskOwnerCap,
    random: &Random,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Assert the Launch requires a Kiosk with place policy.
    launch.assert_kiosk_requirement_place();
    // Assert the Phase is public.
    phase.assert_is_public();

    let items = internal_mint(
        launch,
        phase,
        quantity,
        payment,
        random,
        clock,
        ctx,
    );

    items.destroy!(|item| kiosk.place(kiosk_owner_cap, item));
}

entry fun wl_mint_and_place<T: key + store, C>(
    launch: &mut Launch<T>,
    phase: &mut Phase<T>,
    quantity: u64,
    payment: &mut Coin<C>,
    whitelists: vector<Whitelist>,
    kiosk: &mut Kiosk,
    kiosk_owner_cap: &KioskOwnerCap,
    random: &Random,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Assert the Phase is whitelist.
    phase.assert_is_whitelist();
    // Assert the Launch requires a Kiosk with place policy.
    launch.assert_kiosk_requirement_place();

    let items = internal_mint(
        launch,
        phase,
        quantity,
        payment,
        random,
        clock,
        ctx,
    );

    internal_process_whitelists(whitelists, phase, items.length(), ctx);

    items.destroy!(|item| kiosk.place(kiosk_owner_cap, item));
}

entry fun mint_and_place_in_new_kiosk<T: key + store, C>(
    launch: &mut Launch<T>,
    phase: &mut Phase<T>,
    quantity: u64,
    payment: &mut Coin<C>,
    random: &Random,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Assert the Launch requires a Kiosk with place policy.
    launch.assert_kiosk_requirement_place();
    // Assert the Phase is public.
    phase.assert_is_public();

    let (mut kiosk, kiosk_owner_cap) = kiosk::new(ctx);

    let items = internal_mint(
        launch,
        phase,
        quantity,
        payment,
        random,
        clock,
        ctx,
    );

    items.destroy!(
        |item| kiosk.place(
            &kiosk_owner_cap,
            item,
        ),
    );

    transfer::public_share_object(kiosk);
    transfer::public_transfer(kiosk_owner_cap, ctx.sender());
}

entry fun wl_mint_and_place_in_new_kiosk<T: key + store, C>(
    launch: &mut Launch<T>,
    phase: &mut Phase<T>,
    quantity: u64,
    payment: &mut Coin<C>,
    whitelists: vector<Whitelist>,
    random: &Random,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Assert the Phase is whitelist.
    phase.assert_is_whitelist();
    // Assert the Launch requires a Kiosk with place policy.
    launch.assert_kiosk_requirement_place();

    let (mut kiosk, kiosk_owner_cap) = kiosk::new(ctx);

    let items = internal_mint(
        launch,
        phase,
        quantity,
        payment,
        random,
        clock,
        ctx,
    );

    internal_process_whitelists(whitelists, phase, items.length(), ctx);

    items.destroy!(
        |item| kiosk.place(
            &kiosk_owner_cap,
            item,
        ),
    );

    transfer::public_share_object(kiosk);
    transfer::public_transfer(kiosk_owner_cap, ctx.sender());
}

//=== Private Functions ===

#[allow(lint(self_transfer))]
fun internal_mint<T: key + store, C>(
    launch: &mut Launch<T>,
    phase: &mut Phase<T>,
    quantity: u64,
    payment: &mut Coin<C>,
    random: &Random,
    clock: &Clock,
    ctx: &mut TxContext,
): vector<T> {
    // Assert the Launch is mintable.
    // This performs a check that ensures the Launch is both in ACTIVE state and has items remaining.
    launch.assert_is_mintable();
    // Assert the Phase is mintable.
    // This performs a check that ensures the current timestamp is within the Phase's start and end timestamps.
    phase.assert_is_mintable(clock);
    // Assert quantity is 1 if the Phase does not allow bulk minting.
    if (!phase.is_allow_bulk_mint()) { assert!(quantity == 1, EBulkMintNotAllowed) };
    // Calculate the participant's remaining mint count by substracting the participant's
    // current mint count from the phase's max mint allocation per participant.
    let participant_remaining_mint_count =
        phase.max_mint_count_addr() - phase.participant_mint_count(ctx.sender());
    // Assert the requested quantity is not greater than the participant's remaining mint count.
    assert!(quantity <= participant_remaining_mint_count, EParticipantMintCountExceeded);
    // Assert the max mint count for the phase is not exceeded.
    assert!(quantity <= phase.remaining_mint_count(), EPhaseMaxMintCountExceeded);
    // Get the unit price for the payment type.
    let unit_price = *phase.payment_types().get(&type_name::get<C>());

    if (unit_price > 0) {
        // Calculate the required payment value.
        let required_payment_value = unit_price * quantity;
        // Assert the payment amount is greater than or equal to the unit price multiplied by the quantity.
        assert!(payment.value() >= required_payment_value, EIncorrectPaymentAmount);
        // Get a mutable reference to the payment balance, and split the purchase amount from the payment balance.
        let revenue = payment.balance_mut().split(required_payment_value);
        // Deposit revenue into the Launch.
        launch.deposit_revenue(revenue);
    };

    let mut items: vector<T> = vector[];
    let mut rg = random.new_generator(ctx);
    let mut i = 0;
    while (i < quantity) {
        // Randomly select an item from the Launch.
        let item_idx = rg.generate_u64_in_range(0, launch.items().length() - 1);
        let item = launch.items_mut().swap_remove(item_idx);
        // Emit ItemMintedEvent.
        emit(ItemMintedEvent {
            launch_id: launch.id(),
            phase_id: phase.id(),
            item_id: object::id(&item),
            minted_by: ctx.sender(),
            payment_type: type_name::get<C>(),
            payment_value: unit_price,
        });
        // Add the item to the items vector.
        items.push_back(item);
        // Increment the minted supply for the Launch.
        launch.increment_minted_supply();
        // Increment the current mint count for the Phase.
        phase.increment_mint_count(ctx);
        // Increment the loop counter.
        i = i + 1;
    };

    items
}

#[allow(lint(self_transfer))]
fun internal_process_whitelists<T: key + store>(
    mut whitelists: vector<Whitelist>,
    phase: &Phase<T>,
    quantity: u64,
    ctx: &TxContext,
) {
    // If the phase is a whitelist phase, assert the participant has provided
    // enough whitelists to mint the requested quantity.
    assert!(whitelists.length() >= quantity, EIncorrectWhitelistCount);
    // Assert the provided whitelist tickets are for the current phase.
    whitelists.do_ref!(|wl| assert!(wl.phase_id() == phase.id(), EIncorrectWhitelistForPhase));
    // Destroy `mint_quantity` number of whitelist tickets.
    quantity.do!(|_| whitelists.pop_back().destroy());
    // Return the remaining whitelists.
    whitelists.destroy!(|wl| transfer::public_transfer(wl, ctx.sender()));
}
