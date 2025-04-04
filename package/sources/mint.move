module nexus_launchpad::mint;

use nexus_launchpad::launch::Launch;
use nexus_launchpad::phase::Phase;
use nexus_launchpad::whitelist::Whitelist;
use std::type_name::{Self, TypeName};
use std::u64;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event::emit;
use sui::kiosk::{Self, Kiosk, KioskOwnerCap};
use sui::random::Random;
use sui::transfer_policy::TransferPolicy;

const EBulkMintNotAllowed: u64 = 300;
const EIncorrectPaymentAmount: u64 = 301;
const EIncorrectWhitelistCount: u64 = 302;
const EIncorrectWhitelistForPhase: u64 = 303;
const EInvalidActivePhase: u64 = 304;
const ENoWhitelistRequired: u64 = 305;
const EPhaseMaxMintCountExceeded: u64 = 306;

public struct ItemMintedEvent has copy, drop {
    launch_id: ID,
    phase_id: ID,
    item_id: ID,
    minted_by: address,
    payment_type: TypeName,
    payment_value: u64,
}

entry fun mint<T: key + store, C>(
    launch: &mut Launch<T>,
    phase: &mut Phase<T>,
    quantity: u64,
    payment: &mut Coin<C>,
    whitelists: vector<Whitelist<T>>,
    random: &Random,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    launch.assert_kiosk_requirement_none();

    let items = internal_mint(
        launch,
        phase,
        quantity,
        payment,
        whitelists,
        random,
        clock,
        ctx,
    );

    items.destroy!(|item| transfer::public_transfer(item, ctx.sender()));
}

entry fun mint_and_lock<T: key + store, C>(
    launch: &mut Launch<T>,
    phase: &mut Phase<T>,
    quantity: u64,
    payment: &mut Coin<C>,
    whitelists: vector<Whitelist<T>>,
    kiosk: &mut Kiosk,
    kiosk_owner_cap: &KioskOwnerCap,
    policy: &TransferPolicy<T>,
    random: &Random,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    launch.assert_kiosk_requirement_lock();

    let items = internal_mint(
        launch,
        phase,
        quantity,
        payment,
        whitelists,
        random,
        clock,
        ctx,
    );

    items.destroy!(|item| kiosk.lock(kiosk_owner_cap, policy, item));
}

entry fun mint_and_lock_in_new_kiosk<T: key + store, C>(
    launch: &mut Launch<T>,
    phase: &mut Phase<T>,
    quantity: u64,
    payment: &mut Coin<C>,
    whitelists: vector<Whitelist<T>>,
    policy: &TransferPolicy<T>,
    random: &Random,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    launch.assert_kiosk_requirement_lock();

    let (mut kiosk, kiosk_owner_cap) = kiosk::new(ctx);

    let items = internal_mint(
        launch,
        phase,
        quantity,
        payment,
        whitelists,
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

entry fun mint_and_place<T: key + store, C>(
    launch: &mut Launch<T>,
    phase: &mut Phase<T>,
    quantity: u64,
    payment: &mut Coin<C>,
    whitelists: vector<Whitelist<T>>,
    kiosk: &mut Kiosk,
    kiosk_owner_cap: &KioskOwnerCap,
    random: &Random,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    launch.assert_kiosk_requirement_place();

    let items = internal_mint(
        launch,
        phase,
        quantity,
        payment,
        whitelists,
        random,
        clock,
        ctx,
    );

    items.destroy!(|item| kiosk.place(kiosk_owner_cap, item));
}

entry fun mint_and_place_in_new_kiosk<T: key + store, C>(
    launch: &mut Launch<T>,
    phase: &mut Phase<T>,
    quantity: u64,
    payment: &mut Coin<C>,
    whitelists: vector<Whitelist<T>>,
    random: &Random,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    launch.assert_kiosk_requirement_place();

    let (mut kiosk, kiosk_owner_cap) = kiosk::new(ctx);

    let items = internal_mint(
        launch,
        phase,
        quantity,
        payment,
        whitelists,
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

#[allow(lint(self_transfer))]
fun internal_mint<T: key + store, C>(
    launch: &mut Launch<T>,
    phase: &mut Phase<T>,
    quantity: u64,
    payment: &mut Coin<C>,
    mut whitelists: vector<Whitelist<T>>,
    random: &Random,
    clock: &Clock,
    ctx: &mut TxContext,
): vector<T> {
    // Fetch the active phase ID from the launch.
    //
    // This will error out if:
    //    1. The provided phase object's ID is not the active phase ID.
    //    2. The current timestamp is not within the active phase's time range.
    assert!(launch.active_phase_id(clock) == phase.id(), EInvalidActivePhase);

    // Assert requested quantity is 1 if bulk mint is not allowed.
    if (phase.is_allow_bulk_mint() == false) {
        assert!(quantity == 1, EBulkMintNotAllowed);
    };

    // Calculate the participant's remaining mint count by substracting the participant's
    // current mint count from the phase's max mint allocation per participant.
    let participant_remaining_mint_count =
        phase.max_mint_count_addr() - phase.participant_mint_count(ctx.sender());

    // Update the quantity to the participant's remaining mint count
    // if the requested quantity is greater than the participant's remaining mint count.
    let mint_quantity = u64::min(quantity, participant_remaining_mint_count);

    if (phase.is_whitelist()) {
        // If the phase is a whitelist phase, assert the participant has provided
        // enough whitelists to mint the requested quantity.
        assert!(whitelists.length() >= mint_quantity, EIncorrectWhitelistCount);
        // Assert the provided whitelist tickets are for the current phase.
        whitelists.do_ref!(|wl| assert!(wl.phase_id() == phase.id(), EIncorrectWhitelistForPhase));
        // Destroy `mint_quantity` number of whitelist tickets.
        mint_quantity.do!(|_| whitelists.pop_back().destroy());
    } else {
        // Assert the whitelist vector is empty if the phase is not a whitelist phase.
        assert!(whitelists.is_empty(), ENoWhitelistRequired);
    };

    // Destroy the empty whitelist vector.
    whitelists.destroy!(|wl| transfer::public_transfer(wl, ctx.sender()));

    // Assert the max mint count for the phase is not exceeded.
    assert!(
        phase.current_mint_count() + mint_quantity <= phase.max_mint_count_phase(),
        EPhaseMaxMintCountExceeded,
    );

    // Get the unit price for the payment type.
    let unit_price = *phase.payment_types().get(&type_name::get<C>());

    // Assert the payment amount is greater than or equal to the unit price multiplied by the quantity.
    assert!(payment.value() >= unit_price * mint_quantity, EIncorrectPaymentAmount);

    // Get a mutable reference to the payment balance, and split the purchase amount from the payment balance.
    let revenue = payment.balance_mut().split(unit_price * mint_quantity);

    // Deposit revenue into the Launch.
    launch.deposit_revenue(revenue);
    // If payment balance is non-zero (happens when quantity is reduced from the requested quantity),
    // transfer the unused payment balance back to the participant.

    let mut rg = random.new_generator(ctx);

    let mut items: vector<T> = vector[];
    let mut i = 0;
    while (i < mint_quantity) {
        let item_idx = rg.generate_u64_in_range(0, launch.items().length() - 1);
        let item = launch.items_mut().swap_remove(item_idx);

        emit(ItemMintedEvent {
            launch_id: launch.id(),
            phase_id: phase.id(),
            item_id: object::id(&item),
            minted_by: ctx.sender(),
            payment_type: type_name::get<C>(),
            payment_value: unit_price,
        });

        items.push_back(item);

        // Increment the minted supply for the Launch.
        launch.increment_minted_supply();
        // Increment the current mint count for the Phase.
        phase.increment_current_mint_count();
        // Increment the participant's mint count for the Phase.
        phase.increment_participant_mint_count(ctx.sender());

        i = i + 1;
    };

    items
}
