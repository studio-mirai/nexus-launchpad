module nexus_launchpad::launch;

use std::type_name::{Self, TypeName};
use std::u64;
use sui::bag::{Self, Bag};
use sui::balance::Balance;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::dynamic_field as df;
use sui::event::emit;
use sui::kiosk::{Kiosk, KioskOwnerCap};
use sui::package::{Self, Publisher};
use sui::table_vec::{Self, TableVec};
use sui::transfer_policy::TransferPolicy;
use sui::vec_set::{Self, VecSet};

//=== Method Aliases ===

public use fun launch_admin_cap_authorize as LaunchAdminCap.authorize;
public use fun launch_admin_cap_launch_id as LaunchAdminCap.launch_id;
public use fun launch_operator_cap_authorize as LaunchOperatorCap.authorize;
public use fun launch_operator_cap_launch_id as LaunchOperatorCap.launch_id;

//=== Structs ===

public struct LAUNCH has drop {}

public struct Launch<phantom T: key + store> has key {
    id: UID,
    // Current state of the launch. Refer to the `LaunchState` enum for more details.
    state: LaunchState,
    // Items that are available for mint.
    items: TableVec<T>,
    // Set of Phase IDs associated with the Launch.
    phase_ids: VecSet<ID>,
    // Revenue collected from the launch. Implemented as a Bag to allow for multiple payment types.
    revenue: Bag,
    // An enum indicating whether a launch requires Kiosk (place or lock) or not.
    kiosk_requirement: KioskRequirement,
    // The operators that can manage the phase.
    operators: VecSet<address>,
}

// Capability object for admin-level permissiones.
// Required for withdrawing revenue from the launch.
public struct LaunchAdminCap has key, store {
    id: UID,
    launch_id: ID,
    is_withdrew_revenue: bool,
}

// Capability object for operator-level permissions.
// Required for managing the launch (scheduling phases, changing states, etc.).
// Can be sent to a launchpad operator to delegate launch management.
public struct LaunchOperatorCap has drop {
    launch_id: ID,
}

public struct ShareLaunchPromise {
    launch_id: ID,
}

// Used as a df key for linking other objects to the launch for easy discoverability.
public struct LaunchLink<phantom T: key> has copy, drop, store {}

//=== Enums ===

// An enum indicating whether a launch requires Kiosk (place or lock) or not.
public enum KioskRequirement has copy, drop, store {
    NONE,
    PLACE,
    LOCK,
}

// An enum indicating the state of a launch.
public enum LaunchState has copy, drop, store {
    SUPPLYING { total_supply: u64 },
    ACTIVE { minted_supply: u64 },
    PAUSED { minted_supply: u64 },
    COMPLETED,
}

//=== Events ===
public struct LaunchCreatedEvent has copy, drop {
    launch_id: ID,
    launch_admin_cap_id: ID,
    launch_type: TypeName,
}

public struct ItemAddedEvent has copy, drop {
    launch_id: ID,
    item_type: TypeName,
}

public struct ItemsAddedEvent has copy, drop {
    launch_id: ID,
    item_type: TypeName,
    quantity: u64,
}

public struct ItemsRemovedEvent has copy, drop {
    launch_id: ID,
    item_type: TypeName,
    quantity: u64,
}

public struct SchedulingStateSetEvent has copy, drop {
    launch_id: ID,
}

public struct CompletedStateSetEvent has copy, drop {
    launch_id: ID,
    ts: u64,
}

//=== Constants ===

const MAX_PHASE_COUNT: u64 = 50;

//=== Errors ===

const EExceedsMaxPhaseCount: u64 = 10001;
const EExceedsTargetSupply: u64 = 10002;
const EInvalidLaunchAdminCap: u64 = 10003;
const EInvalidLaunchId: u64 = 10004;
const EInvalidLaunchOperatorCap: u64 = 10005;
const EInvalidPublisher: u64 = 10006;
const EInvalidState: u64 = 10007;
const ENotKioskRequirementLock: u64 = 10008;
const ENotKioskRequirementNone: u64 = 10009;
const ENotKioskRequirementPlace: u64 = 10010;
const ENotMintable: u64 = 10011;
const EItemsNotEmpty: u64 = 10012;
const ENoRemainingSupply: u64 = 10013;
const EPhasesNotDestroyed: u64 = 10014;
const ETotalSupplyNotReached: u64 = 10015;
const EAdminCapNotWithdrewRevenue: u64 = 10016;
const ENotOperator: u64 = 10017;

//=== Init Function ===

fun init(otw: LAUNCH, ctx: &mut TxContext) {
    let publisher = package::claim(otw, ctx);
    transfer::public_transfer(publisher, ctx.sender());
}

//=== Public Functions ===

// Create a new Launch.
public fun new<T: key + store>(
    publisher: &Publisher,
    total_supply: u64,
    kiosk_requirement: KioskRequirement,
    ctx: &mut TxContext,
): (Launch<T>, LaunchAdminCap, ShareLaunchPromise) {
    assert!(publisher.from_module<T>() == true, EInvalidPublisher);

    let mut launch = Launch<T> {
        id: object::new(ctx),
        state: LaunchState::SUPPLYING { total_supply: total_supply },
        items: table_vec::empty(ctx),
        phase_ids: vec_set::empty(),
        revenue: bag::new(ctx),
        kiosk_requirement: kiosk_requirement,
        operators: vec_set::empty(),
    };

    let launch_admin_cap = LaunchAdminCap {
        id: object::new(ctx),
        launch_id: launch.id(),
        is_withdrew_revenue: false,
    };

    let promise = ShareLaunchPromise {
        launch_id: launch.id(),
    };

    // Link admin/operator caps to launch for easy discoverability.
    launch.new_launch_link(&launch_admin_cap, &launch_admin_cap);

    emit(LaunchCreatedEvent {
        launch_id: launch.id(),
        launch_admin_cap_id: launch_admin_cap.id.to_inner(),
        launch_type: type_name::get<T>(),
    });

    (launch, launch_admin_cap, promise)
}

// Create a new `KioskRequirement` with `NONE` variant.
// Used for enforcing a mint claiming behavior.
public fun new_kiosk_requirement_none(): KioskRequirement {
    KioskRequirement::NONE
}

// Create a new `KioskRequirement` with `PLACE` variant.
// Used for enforcing a mint claiming behavior.
public fun new_kiosk_requirement_place(): KioskRequirement {
    KioskRequirement::PLACE
}

// Create a new `KioskRequirement` with `LOCK` variant.
// Used for enforcing a mint claiming behavior.
public fun new_kiosk_requirement_lock(): KioskRequirement {
    KioskRequirement::LOCK
}

// Ensures a Launch is created as a shared object.
public fun share<T: key + store>(self: Launch<T>, promise: ShareLaunchPromise) {
    assert!(promise.launch_id == self.id(), EInvalidLaunchId);
    let ShareLaunchPromise { .. } = promise;
    transfer::share_object(self);
}

// Add an Item of type `T` to a Launch.
public fun add_item<T: key + store>(self: &mut Launch<T>, cap: &LaunchOperatorCap, item: T) {
    // Verify the LaunchOperatorCap matches the Launch.
    cap.authorize(self.id());

    match (self.state) {
        // An item can only be added to a Launch in SUPPLYING state.
        LaunchState::SUPPLYING { total_supply } => {
            // Assert that adding an item will not exceed the total supply.
            assert!(self.items.length() + 1 <= total_supply, EExceedsTargetSupply);
            // Emit ItemAddedEvent.
            emit(ItemAddedEvent {
                launch_id: self.id(),
                item_type: type_name::get<T>(),
            });
            // Add the item to the Launch.
            self.items.push_back(item);
        },
        _ => abort EInvalidState,
    };
}

// Add items of type `T` to a Launch.
public fun add_items<T: key + store>(
    self: &mut Launch<T>,
    cap: &LaunchOperatorCap,
    items: vector<T>,
) {
    // Verify the LaunchOperatorCap matches the Launch.
    cap.authorize(self.id());

    match (self.state) {
        // Items can only be added to a Launch in SUPPLYING state.
        LaunchState::SUPPLYING { total_supply } => {
            // Assert that adding the items will not exceed the total supply.
            assert!(self.items.length() + items.length() <= total_supply, EExceedsTargetSupply);
            // Emit ItemsAddedEvent.
            emit(ItemsAddedEvent {
                launch_id: self.id(),
                item_type: type_name::get<T>(),
                quantity: items.length(),
            });
            // Add the items to the Launch.
            items.destroy!(|item| self.items.push_back(item));
        },
        _ => abort EInvalidState,
    };
}

// Remove items from a Launch in SUPPLYING state.
public fun remove_items<T: key + store>(
    self: &mut Launch<T>,
    cap: &LaunchOperatorCap,
    quantity: u64,
): vector<T> {
    cap.authorize(self.id());

    match (self.state) {
        LaunchState::SUPPLYING { .. } => {
            let withdraw_quantity = u64::min(quantity, self.items.length());

            emit(ItemsRemovedEvent {
                launch_id: self.id(),
                item_type: type_name::get<T>(),
                quantity: quantity,
            });

            vector::tabulate!(withdraw_quantity, |_| self.items.pop_back())
        },
        _ => abort EInvalidState,
    }
}

// Transitions a Launch from SUPPLYING to ACTIVE state.
public fun set_active_state<T: key + store>(self: &mut Launch<T>, cap: &LaunchOperatorCap) {
    // Verify the LaunchOperatorCap matches the Launch.
    cap.authorize(self.id());

    match (self.state) {
        LaunchState::SUPPLYING { total_supply } => {
            // Assert that the Launch has reached its total supply.
            assert!(self.items.length() == total_supply, ETotalSupplyNotReached);
            // Emit SchedulingStateSetEvent.
            emit(SchedulingStateSetEvent {
                launch_id: self.id(),
            });
            // Transition the Launch to ACTIVE state.
            self.state = LaunchState::ACTIVE { minted_supply: 0 };
        },
        LaunchState::PAUSED { minted_supply } => {
            // Transition the Launch to ACTIVE state.
            self.state = LaunchState::ACTIVE { minted_supply };
        },
        _ => abort EInvalidState,
    }
}

// Transition a Launch from ACTIVE to PAUSED state.
public fun set_paused_state<T: key + store>(self: &mut Launch<T>, cap: &LaunchOperatorCap) {
    cap.authorize(self.id());

    match (self.state) {
        LaunchState::ACTIVE { minted_supply } => {
            self.state = LaunchState::PAUSED { minted_supply };
        },
        _ => {},
    }
}

// Transitions a Launch from ACTIVE to COMPLETED state.
// Requires that the Launch has no items remaining.
public fun set_completed_state<T: key + store>(
    self: &mut Launch<T>,
    cap: &LaunchOperatorCap,
    clock: &Clock,
) {
    cap.authorize(self.id());

    match (self.state) {
        LaunchState::ACTIVE { .. } => {
            // Assert that the Launch has no items remaining.
            assert!(self.items.is_empty(), EItemsNotEmpty);
            // Transition the Launch to COMPLETED state.
            self.state = LaunchState::COMPLETED;
            // Emit an event to indicate the Launch has been completed.
            emit(CompletedStateSetEvent {
                launch_id: self.id(),
                ts: clock.timestamp_ms(),
            });
        },
        _ => abort EInvalidState,
    }
}

// Withdraw `quantity` items from a Launch.
// This might need to be called multiple times to withdraw all items.
public fun withdraw_items<T: key + store>(
    self: &mut Launch<T>,
    cap: &mut LaunchOperatorCap,
    mut quantity: u64,
): vector<T> {
    // Verify the LaunchOperatorCap matches the Launch.
    cap.authorize(self.id());
    // Assert that the Launch has no Kiosk requirement.
    self.assert_kiosk_requirement_none();

    match (self.state) {
        LaunchState::ACTIVE { .. } => {
            assert!(!self.items.is_empty(), ENoRemainingSupply);
            quantity = u64::min(quantity, self.items.length());
            vector::tabulate!(quantity, |_| self.items.pop_back())
        },
        _ => abort EInvalidState,
    }
}

// Withdraw `quantity` items from a Launch.
// This might need to be called multiple times to withdraw all items.
public fun withdraw_items_and_place_in_kiosk<T: key + store>(
    self: &mut Launch<T>,
    cap: &mut LaunchOperatorCap,
    mut quantity: u64,
    kiosk: &mut Kiosk,
    kiosk_owner_cap: &KioskOwnerCap,
) {
    // Verify the LaunchOperatorCap matches the Launch.
    cap.authorize(self.id());
    // Assert that the Launch has a PLACE Kiosk requirement.
    self.assert_kiosk_requirement_place();

    match (self.state) {
        LaunchState::ACTIVE { .. } => {
            assert!(!self.items.is_empty(), ENoRemainingSupply);
            quantity = u64::min(quantity, self.items.length());
            let items = vector::tabulate!(quantity, |_| self.items.pop_back());
            items.destroy!(|item| kiosk.place(kiosk_owner_cap, item));
        },
        _ => abort EInvalidState,
    }
}

// Withdraw `quantity` items from a Launch.
// This might need to be called multiple times to withdraw all items.
public fun withdraw_items_and_lock_in_kiosk<T: key + store>(
    self: &mut Launch<T>,
    cap: &mut LaunchOperatorCap,
    mut quantity: u64,
    kiosk: &mut Kiosk,
    kiosk_owner_cap: &KioskOwnerCap,
    policy: &TransferPolicy<T>,
) {
    // Verify the LaunchOperatorCap matches the Launch.
    cap.authorize(self.id());
    // Assert that the Launch has a LOCK Kiosk requirement.
    self.assert_kiosk_requirement_lock();

    match (self.state) {
        LaunchState::ACTIVE { .. } => {
            assert!(!self.items.is_empty(), ENoRemainingSupply);
            quantity = u64::min(quantity, self.items.length());
            let items = vector::tabulate!(quantity, |_| self.items.pop_back());
            items.destroy!(|item| kiosk.lock(kiosk_owner_cap, policy, item));
        },
        _ => abort EInvalidState,
    }
}

// Withdraws revenue of the provided type from a Launch.
public fun withdraw_revenue<T: key + store, C>(
    self: &mut Launch<T>,
    cap: &mut LaunchAdminCap,
    ctx: &mut TxContext,
): Coin<C> {
    // Verify the LaunchAdminCap matches the Launch.
    cap.authorize(self.id());
    // Remove the revenue from the Launch.
    let balance: Balance<C> = self.revenue.remove(type_name::get<C>());
    // Set `is_withdrew_revenue` to true if all revenue has been withdrawn.
    if (self.revenue.is_empty()) {
        cap.is_withdrew_revenue = true;
    };
    // Convert the balance to a Coin.
    coin::from_balance(balance, ctx)
}

// Destroy a Launch with the LaunchOperatorCap.
// Requirements:
// - The Launch must be in COMPLETED state.
// - Phases must have been destroyed.
public fun destroy<T: key + store>(self: Launch<T>, cap: &LaunchOperatorCap) {
    // Verify the LaunchOperatorCap matches the Launch.
    cap.authorize(self.id());

    match (self.state) {
        LaunchState::COMPLETED => {
            // Assert that Phases have been destroyed.
            assert!(self.phase_ids.is_empty(), EPhasesNotDestroyed);
            // Destroy the Launch.
            let Launch { id, items, revenue, .. } = self;
            id.delete();
            // Will abort if there are items remaining.
            items.destroy_empty();
            // Will abort if there are revenue balances remaining.
            revenue.destroy_empty();
        },
        _ => abort EInvalidState,
    }
}

// Add an operator to the Launch.
public fun add_operator<T: key + store>(
    self: &mut Launch<T>,
    cap: &LaunchAdminCap,
    operator: address,
) {
    cap.authorize(self.id());
    self.operators.insert(operator);
}

// Remove an operator from the Launch.
public fun remove_operator<T: key + store>(
    self: &mut Launch<T>,
    cap: &LaunchAdminCap,
    operator: address,
) {
    cap.authorize(self.id());
    self.operators.remove(&operator);
}

public fun request_operator_cap<T: key + store>(
    self: &Launch<T>,
    ctx: &TxContext,
): LaunchOperatorCap {
    assert!(self.operators.contains(&ctx.sender()), ENotOperator);
    LaunchOperatorCap {
        launch_id: self.id(),
    }
}

// Create a new launch link.
public fun new_launch_link<T: key + store, L: key>(
    self: &mut Launch<T>,
    cap: &LaunchAdminCap,
    obj: &L,
) {
    cap.authorize(self.id());
    df::add(&mut self.id, LaunchLink<L> {}, object::id(obj));
}

// Remove a launch link.
public fun remove_launch_link<T: key + store, L: key>(self: &mut Launch<T>, cap: &LaunchAdminCap) {
    cap.authorize(self.id());
    df::remove<LaunchLink<L>, ID>(&mut self.id, LaunchLink<L> {});
}

// Destroy the LaunchAdminCap to claim a storage rebate.
// Requires `is_withdrew_revenue` to be true, which is set when `withdraw_revenue()` is called,
// and the Launch has no revenue balances left.
public fun launch_admin_cap_destroy(cap: LaunchAdminCap) {
    assert!(cap.is_withdrew_revenue == true, EAdminCapNotWithdrewRevenue);
    let LaunchAdminCap { id, .. } = cap;
    id.delete();
}

// Register a Phase with the Launch.
public(package) fun register_phase<T: key + store>(self: &mut Launch<T>, phase_id: ID) {
    assert!(self.phase_ids.size() < MAX_PHASE_COUNT, EExceedsMaxPhaseCount);
    self.phase_ids.insert(phase_id);
}

// Unregister a Phase with the Launch.
public(package) fun unregister_phase<T: key + store>(self: &mut Launch<T>, phase_id: ID) {
    self.phase_ids.remove(&phase_id);
}

// Description: Deposit revenue (Balance<C>) into the Launch.
public(package) fun deposit_revenue<T: key + store, C>(self: &mut Launch<T>, revenue: Balance<C>) {
    let revenue_type = type_name::get<C>();
    if (!self.revenue.contains(revenue_type)) {
        self.revenue.add(revenue_type, revenue);
    } else {
        let balance: &mut Balance<C> = self.revenue.borrow_mut(revenue_type);
        balance.join(revenue);
    };
}

public(package) fun increment_minted_supply<T: key + store>(self: &mut Launch<T>) {
    match (self.state) {
        LaunchState::ACTIVE { minted_supply } => {
            self.state = LaunchState::ACTIVE { minted_supply: minted_supply + 1 };
        },
        _ => abort EInvalidState,
    }
}

// Returns the number of items in the Launch.
public(package) fun supply<T: key + store>(self: &Launch<T>): u64 {
    self.items.length()
}

// Returns a reference to the items in the Launch.
public(package) fun items<T: key + store>(self: &Launch<T>): &TableVec<T> {
    &self.items
}

// Returns a mutable reference to the items in the Launch.
public(package) fun items_mut<T: key + store>(self: &mut Launch<T>): &mut TableVec<T> {
    &mut self.items
}

// Returns a reference to the revenue in the Launch.
public(package) fun revenue<T: key + store>(self: &Launch<T>): &Bag {
    &self.revenue
}

// Returns a mutable reference to the revenue in the Launch.
public(package) fun revenue_mut<T: key + store>(self: &mut Launch<T>): &mut Bag {
    &mut self.revenue
}

// Authorizes a LaunchAdminCap to access a Launch.
public(package) fun launch_admin_cap_authorize(cap: &LaunchAdminCap, launch_id: ID) {
    assert!(cap.launch_id == launch_id, EInvalidLaunchAdminCap);
}

// Authorizes a LaunchOperatorCap to access a Launch.
public(package) fun launch_operator_cap_authorize(cap: &LaunchOperatorCap, launch_id: ID) {
    assert!(cap.launch_id == launch_id, EInvalidLaunchOperatorCap);
}

public fun id<T: key + store>(self: &Launch<T>): ID {
    self.id.to_inner()
}

public fun launch_admin_cap_launch_id(cap: &LaunchAdminCap): ID {
    cap.launch_id
}

public fun launch_operator_cap_launch_id(cap: &LaunchOperatorCap): ID {
    cap.launch_id
}

// Returns true if the Launch is in SUPPLYING state.
public fun is_supplying_state<T: key + store>(self: &Launch<T>): bool {
    match (self.state) {
        LaunchState::SUPPLYING { .. } => true,
        _ => false,
    }
}

// Returns true if the Launch is in ACTIVE state.
public fun is_active_state<T: key + store>(self: &Launch<T>): bool {
    match (self.state) {
        LaunchState::ACTIVE { .. } => true,
        _ => false,
    }
}

// Returns true if the Launch is in PAUSED state.
public fun is_paused_state<T: key + store>(self: &Launch<T>): bool {
    match (self.state) {
        LaunchState::PAUSED { .. } => true,
        _ => false,
    }
}

// Returns true if the Launch is in COMPLETED state.
public fun is_completed_state<T: key + store>(self: &Launch<T>): bool {
    match (self.state) {
        LaunchState::COMPLETED => true,
        _ => false,
    }
}

// Description: Assert that the Launch has no Kiosk requirement.
public fun assert_kiosk_requirement_none<T: key + store>(self: &Launch<T>) {
    assert!(self.kiosk_requirement == KioskRequirement::NONE, ENotKioskRequirementNone);
}

// Description: Assert that the Launch has a PLACE Kiosk requirement.
public fun assert_kiosk_requirement_place<T: key + store>(self: &Launch<T>) {
    assert!(self.kiosk_requirement == KioskRequirement::PLACE, ENotKioskRequirementPlace);
}

// Description: Assert that the Launch has a LOCK Kiosk requirement.
public fun assert_kiosk_requirement_lock<T: key + store>(self: &Launch<T>) {
    assert!(self.kiosk_requirement == KioskRequirement::LOCK, ENotKioskRequirementLock);
}

// Assert the Launch is in SUPPLYING state.
public fun assert_is_supplying_state<T: key + store>(self: &Launch<T>) {
    assert!(self.is_supplying_state(), EInvalidState);
}

// Assert the Launch is in ACTIVE state.
public fun assert_is_active_state<T: key + store>(self: &Launch<T>) {
    assert!(self.is_active_state(), EInvalidState);
}

// Assert the Launch is in PAUSED state.
public fun assert_is_paused_state<T: key + store>(self: &Launch<T>) {
    assert!(self.is_paused_state(), EInvalidState);
}

// Assert the Launch is in COMPLETED state.
public fun assert_is_completed_state<T: key + store>(self: &Launch<T>) {
    assert!(self.is_completed_state(), EInvalidState);
}

// Assert the Launch is mintable, which means it's both in ACTIVE state and has items remaining.
public fun assert_is_mintable<T: key + store>(self: &Launch<T>) {
    match (self.state) {
        LaunchState::ACTIVE { .. } => {
            assert!(self.items.length() > 0, ENoRemainingSupply);
        },
        _ => abort ENotMintable,
    }
}
