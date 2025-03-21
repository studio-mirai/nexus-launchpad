module nexus_launchpad::launch;

use nexus_launchpad::quicksort::quicksort;
use nexus_launchpad::utils::{ts_to_range, range_to_ts};
use std::type_name::{Self, TypeName};
use sui::bag::{Self, Bag};
use sui::balance::Balance;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::dynamic_field as df;
use sui::event::emit;
use sui::package::{Self, Publisher};
use sui::table_vec::{Self, TableVec};
use sui::transfer::Receiving;
use sui::vec_map::{Self, VecMap};

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
    // Phase IDs mapped to a u128 derived from the u64 start and end timestamps.
    // This is used to sort the phases, and to ensure there are no overlaps.
    phase_ids: VecMap<ID, u128>,
    // Revenue collected from the launch. Implemented as a Bag to allow for multiple payment types.
    revenue: Bag,
    // An enum indicating whether a launch requires Kiosk (place or lock) or not.
    kiosk_requirement: KioskRequirement,
    // The total supply of the launch.
    total_supply: u64,
}

// Capability object for admin-level permissiones.
// Required for withdrawing revenue from the launch.
public struct LaunchAdminCap has key, store {
    id: UID,
    launch_id: ID,
}

// Capability object for operator-level permissions.
// Required for managing the launch (scheduling phases, changing states, etc.).
// Can be sent to a launchpad operator to delegate launch management.
public struct LaunchOperatorCap has key, store {
    id: UID,
    launch_id: ID,
}

public struct ShareLaunchPromise {
    launch_id: ID,
}

// Used as a df key for linking other objects to the launch for easy discoverability.
public struct LaunchLink<phantom T: key> has copy, drop, store {}

public enum KioskRequirement has copy, drop, store {
    NONE,
    PLACE,
    LOCK,
}

public enum LaunchState has copy, drop, store {
    SUPPLYING,
    SCHEDULING,
    ACTIVE { phase_id: ID, start_ts: u64, end_ts: u64, minted_supply: u64 },
    PAUSED { phase_id: ID, start_ts: u64, end_ts: u64, minted_supply: u64 },
    COMPLETED,
}

//=== Events ===

public struct LaunchCreatedEvent has copy, drop {
    launch_id: ID,
    launch_admin_cap_id: ID,
    launch_operator_cap_id: ID,
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

public struct ReadyStateSetEvent has copy, drop {
    launch_id: ID,
    phase_id: ID,
    start_ts: u64,
    end_ts: u64,
}

public struct LaunchPhaseAdvancedEvent has copy, drop {
    from_phase_id: ID,
    from_phase_idx: u64,
    to_phase_id: ID,
    to_phase_idx: u64,
    start_ts: u64,
    end_ts: u64,
}

public struct CompletedStateSetEvent has copy, drop {
    launch_id: ID,
    ts: u64,
}

public struct PausedStateSetEvent has copy, drop {
    launch_id: ID,
    phase_id: ID,
}

//=== Errors ===

const EExceedsCurrentSupply: u64 = 100;
const EInvalidLaunchAdminCap: u64 = 101;
const EInvalidLaunchId: u64 = 102;
const EInvalidLaunchOperatorCap: u64 = 103;
const EInvalidState: u64 = 104;
const ELaunchAlreadyStarted: u64 = 105;
const ENotLastPhase: u64 = 106;
const EPhaseTimeOverlap: u64 = 107;
const ENotKioskRequirementNone: u64 = 108;
const ENotKioskRequirementPlace: u64 = 109;
const ENotKioskRequirementLock: u64 = 110;
const EInvalidPublisher: u64 = 111;
const EPhaseNotStarted: u64 = 112;
const EPhaseEnded: u64 = 113;
const EPhaseNotEnded: u64 = 114;
const EInvalidSupply: u64 = 115;
const ENoNextPhase: u64 = 116;

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
): (Launch<T>, LaunchAdminCap, LaunchOperatorCap, ShareLaunchPromise) {
    assert!(publisher.from_module<T>() == true, EInvalidPublisher);

    let mut launch = Launch<T> {
        id: object::new(ctx),
        state: LaunchState::SUPPLYING,
        items: table_vec::empty(ctx),
        phase_ids: vec_map::empty(),
        revenue: bag::new(ctx),
        kiosk_requirement: kiosk_requirement,
        total_supply: total_supply,
    };

    let launch_admin_cap = LaunchAdminCap {
        id: object::new(ctx),
        launch_id: launch.id(),
    };

    let launch_operator_cap = LaunchOperatorCap {
        id: object::new(ctx),
        launch_id: launch.id(),
    };

    let promise = ShareLaunchPromise {
        launch_id: launch.id(),
    };

    // Link admin/operator caps to launch for easy discoverability.
    df::add(&mut launch.id, LaunchLink<LaunchAdminCap> {}, object::id(&launch_admin_cap));
    df::add(&mut launch.id, LaunchLink<LaunchOperatorCap> {}, object::id(&launch_operator_cap));

    emit(LaunchCreatedEvent {
        launch_id: launch.id(),
        launch_admin_cap_id: launch_admin_cap.id.to_inner(),
        launch_operator_cap_id: launch_operator_cap.id.to_inner(),
        launch_type: type_name::get<T>(),
    });

    (launch, launch_admin_cap, launch_operator_cap, promise)
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

public fun add_item<T: key + store>(self: &mut Launch<T>, cap: &LaunchOperatorCap, item: T) {
    cap.authorize(self.id());

    match (self.state) {
        LaunchState::SUPPLYING => {
            assert!(self.items.length() < self.total_supply, EExceedsCurrentSupply);

            emit(ItemAddedEvent {
                launch_id: self.id(),
                item_type: type_name::get<T>(),
            });

            self.items.push_back(item);
        },
        _ => abort EInvalidState,
    };
}

// Add items to a Launch.
public fun add_items<T: key + store>(
    self: &mut Launch<T>,
    cap: &LaunchOperatorCap,
    items: vector<T>,
) {
    cap.authorize(self.id());

    match (self.state) {
        LaunchState::SUPPLYING => {
            assert!(
                self.items.length() + items.length() <= self.total_supply,
                EExceedsCurrentSupply,
            );

            emit(ItemsAddedEvent {
                launch_id: self.id(),
                item_type: type_name::get<T>(),
                quantity: items.length(),
            });

            items.do!(|item| self.items.push_back(item));
        },
        _ => abort EInvalidState,
    };
}

// Receive items that have been sent to the Launch directly, and add them.
public fun receive_and_add_item<T: key + store>(
    self: &mut Launch<T>,
    item_to_receive: Receiving<T>,
) {
    let item = transfer::public_receive(&mut self.id, item_to_receive);
    self.items.push_back(item);
}

// Remove items from a Launch in SUPPLYING or COMPLETED state.
public fun remove_items<T: key + store>(
    self: &mut Launch<T>,
    cap: &LaunchOperatorCap,
    quantity: u64,
): vector<T> {
    cap.authorize(self.id());

    match (self.state) {
        LaunchState::SCHEDULING => abort EInvalidState,
        LaunchState::ACTIVE { .. } => abort EInvalidState,
        LaunchState::PAUSED { .. } => abort EInvalidState,
        _ => {
            assert!(quantity >= self.items.length(), EExceedsCurrentSupply);

            let mut items: vector<T> = vector[];

            let mut i = 0;
            while (i < quantity) {
                items.push_back(self.items.pop_back());
                i = i + 1;
            };

            emit(ItemsRemovedEvent {
                launch_id: self.id(),
                item_type: type_name::get<T>(),
                quantity: quantity,
            });

            items
        },
    }
}

// Transitions a Launch from SUPPLYING or ACTIVE to SCHEDULING state.
public fun set_scheduling_state<T: key + store>(
    self: &mut Launch<T>,
    cap: &LaunchOperatorCap,
    clock: &Clock,
) {
    cap.authorize(self.id());

    match (self.state) {
        LaunchState::SUPPLYING => {
            assert!(self.items.length() == self.total_supply, EInvalidSupply);

            emit(SchedulingStateSetEvent {
                launch_id: self.id(),
            });

            self.state = LaunchState::SCHEDULING;
        },
        // To transition from ACTIVE back to SCHEDULING,
        // the current timestamp must be before the start timestamp of the first phase.
        LaunchState::ACTIVE { .. } => {
            self.assert_not_started(clock);
            self.state = LaunchState::SCHEDULING;
        },
        _ => abort EInvalidState,
    }
}

// Transitions a Launch from SCHEDULING or PAUSED to ACTIVE state.
public fun set_active_state<T: key + store>(self: &mut Launch<T>, cap: &LaunchOperatorCap) {
    cap.authorize(self.id());

    match (self.state) {
        LaunchState::SCHEDULING => {
            // Sort phases by start timestamp.
            self.sort_phases();

            // Get ID and timestamp details for the first phase.
            let (phase_id, ts_range) = self.phase_ids.get_entry_by_idx(0);
            let (start_ts, end_ts) = range_to_ts(*ts_range);

            emit(ReadyStateSetEvent {
                launch_id: self.id(),
                phase_id: *phase_id,
                start_ts: start_ts,
                end_ts: end_ts,
            });

            // Set the launch state to READY with the first phase's details.
            self.state =
                LaunchState::ACTIVE {
                    phase_id: *phase_id,
                    start_ts: start_ts,
                    end_ts: end_ts,
                    minted_supply: 0,
                };
        },
        LaunchState::PAUSED { phase_id, start_ts, end_ts, minted_supply } => {
            self.state =
                LaunchState::ACTIVE {
                    phase_id: phase_id,
                    start_ts: start_ts,
                    end_ts: end_ts,
                    minted_supply: minted_supply,
                };
        },
        _ => abort EInvalidState,
    }
}

public fun set_paused_state<T: key + store>(self: &mut Launch<T>, cap: &LaunchOperatorCap) {
    cap.authorize(self.id());

    match (self.state) {
        LaunchState::ACTIVE { phase_id, start_ts, end_ts, minted_supply } => {
            emit(PausedStateSetEvent {
                launch_id: self.id(),
                phase_id: phase_id,
            });

            self.state =
                LaunchState::PAUSED {
                    phase_id: phase_id,
                    start_ts: start_ts,
                    end_ts: end_ts,
                    minted_supply: minted_supply,
                };
        },
        _ => abort EInvalidState,
    }
}

// Transitions a Launch from REVEALING to COMPLETED state.
public fun set_completed_state<T: key + store>(
    self: &mut Launch<T>,
    cap: &LaunchOperatorCap,
    clock: &Clock,
) {
    cap.authorize(self.id());

    match (self.state) {
        LaunchState::ACTIVE { phase_id, .. } => {
            // Get the index of the current phase.
            let phase_idx = self.phase_ids.get_idx(&phase_id);
            // Assert that the current phase is the last phase.
            assert!(phase_idx == self.phase_ids.size() - 1, ENotLastPhase);
            // Fetch details about the last phase.
            let (_, _, end_ts) = get_last_phase_details(self);
            // Assert that the last phase has ended.
            assert!(clock.timestamp_ms() >= end_ts, EPhaseNotEnded);
            // Set the Launch to COMPLETED state.
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

// Withdraws revenue of the provided type from a Launch.
// Only allowed when the Launch is in COMPLETED state.
public fun withdraw_revenue<T: key + store, C>(
    self: &mut Launch<T>,
    cap: &LaunchAdminCap,
    ctx: &mut TxContext,
): Coin<C> {
    cap.authorize(self.id());

    match (self.state) {
        LaunchState::COMPLETED => {
            let balance: Balance<C> = self.revenue.remove(type_name::get<C>());
            let coin = coin::from_balance(balance, ctx);

            coin
        },
        _ => abort EInvalidState,
    }
}

// Advance to the next Phase if the current Phase has ended.
public fun advance_phase<T: key + store>(
    self: &mut Launch<T>,
    cap: &LaunchOperatorCap,
    clock: &Clock,
) {
    cap.authorize(self.id());

    match (self.state) {
        LaunchState::ACTIVE { phase_id, end_ts, minted_supply, .. } => {
            // Verify that the current phase has ended.
            assert!(clock.timestamp_ms() >= end_ts, EPhaseNotEnded);

            // Assert that there is a next phase.
            let phase_idx = self.phase_ids.get_idx(&phase_id);
            let next_phase_idx = phase_idx + 1;
            assert!(next_phase_idx < self.phase_ids.size(), ENoNextPhase);

            // Fetch details about the next phase.
            let (next_phase_id, next_ts_range) = self.phase_ids.get_entry_by_idx(next_phase_idx);
            let (next_phase_start_ts, next_phase_end_ts) = range_to_ts(*next_ts_range);

            emit(LaunchPhaseAdvancedEvent {
                from_phase_id: phase_id,
                from_phase_idx: phase_idx,
                to_phase_id: *next_phase_id,
                to_phase_idx: next_phase_idx,
                start_ts: next_phase_start_ts,
                end_ts: next_phase_end_ts,
            });

            self.state =
                LaunchState::ACTIVE {
                    phase_id: *next_phase_id,
                    start_ts: next_phase_start_ts,
                    end_ts: next_phase_end_ts,
                    minted_supply: minted_supply,
                };
        },
        _ => abort EInvalidState,
    }
}

// Only return the active phase ID if the current timestamp is within the active phase's time range.
public(package) fun active_phase_id<T: key + store>(self: &Launch<T>, clock: &Clock): ID {
    match (self.state) {
        LaunchState::ACTIVE { phase_id, start_ts, end_ts, .. } => {
            assert!(clock.timestamp_ms() >= start_ts, EPhaseNotStarted);
            assert!(clock.timestamp_ms() < end_ts, EPhaseEnded);
            phase_id
        },
        _ => abort EInvalidState,
    }
}

// Schedule a Phase for a Launch.
public(package) fun schedule_phase<T: key + store>(
    self: &mut Launch<T>,
    phase_id: ID,
    start_ts: u64,
    end_ts: u64,
) {
    match (self.state) {
        LaunchState::SCHEDULING => {
            // Loop through the scheduled phases to ensure the the proposed start/end timestamps
            // do not overlap with any of the existing phases.
            let phases_len = self.phase_ids.size();
            let mut i = 0;
            while (i < phases_len) {
                let (_, existing_phase_tx_range) = self.phase_ids.get_entry_by_idx(i);
                let (existing_phase_start_ts, existing_phase_end_ts) = range_to_ts(
                    *existing_phase_tx_range,
                );
                assert!(
                    end_ts <= existing_phase_start_ts || start_ts >= existing_phase_end_ts,
                    EPhaseTimeOverlap,
                );
                i = i + 1;
            };
            // If the phase ID already exists, it means the phase is being rescheduled,
            // in which case, just update the phase's time range.
            if (self.phase_ids.contains(&phase_id)) {
                let ts_range = self.phase_ids.get_mut(&phase_id);
                *ts_range = ts_to_range(start_ts, end_ts);
            } else {
                // Insert the new phase details into the launch.
                self.phase_ids.insert(phase_id, ts_to_range(start_ts, end_ts));
            };
            // Sort phases by start timestamp.
            self.sort_phases();
        },
        _ => abort EInvalidState,
    }
}

// Unschedule a Phase from a Launch.
public(package) fun unschedule_phase<T: key + store>(self: &mut Launch<T>, phase_id: ID) {
    match (self.state) {
        LaunchState::SCHEDULING => {
            self.phase_ids.remove(&phase_id);
        },
        _ => abort EInvalidState,
    }
}

// Description: Increment the minted supply by `quantity` when a Launch is in ACTIVE state.
// Required State(s): ACTIVE
public(package) fun increment_minted_supply<T: key + store>(self: &mut Launch<T>) {
    match (&mut self.state) {
        LaunchState::ACTIVE { minted_supply, .. } => {
            *minted_supply = *minted_supply + 1;
        },
        _ => abort EInvalidState,
    }
}

// Description: Deposit revenue (Balance<C>) into the Launch.
public(package) fun deposit_revenue<T: key + store, C>(self: &mut Launch<T>, revenue: Balance<C>) {
    match (self.state) {
        LaunchState::ACTIVE { .. } => {
            let revenue_type = type_name::get<C>();
            if (!self.revenue.contains(revenue_type)) {
                self.revenue.add(revenue_type, revenue);
            } else {
                let balance: &mut Balance<C> = self.revenue.borrow_mut(revenue_type);
                balance.join(revenue);
            };
        },
        _ => abort EInvalidState,
    }
}

public(package) fun total_supply<T: key + store>(self: &Launch<T>): u64 {
    self.total_supply
}

public(package) fun items<T: key + store>(self: &Launch<T>): &TableVec<T> {
    &self.items
}

public(package) fun items_mut<T: key + store>(self: &mut Launch<T>): &mut TableVec<T> {
    &mut self.items
}

public(package) fun revenue<T: key + store>(self: &Launch<T>): &Bag {
    &self.revenue
}

public(package) fun revenue_mut<T: key + store>(self: &mut Launch<T>): &mut Bag {
    &mut self.revenue
}

public(package) fun launch_admin_cap_authorize(cap: &LaunchAdminCap, launch_id: ID) {
    assert!(cap.launch_id == launch_id, EInvalidLaunchAdminCap);
}

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

// Description: Assert that the Launch is in COMPLETED state.
public(package) fun assert_is_completed<T: key + store>(self: &Launch<T>) {
    assert!(self.state == LaunchState::COMPLETED, EInvalidState);
}

// Description: Get the details of the last Phase of a Launch.
fun get_last_phase_details<T: key + store>(self: &Launch<T>): (ID, u64, u64) {
    let phase_count = self.phase_ids.size();
    let (phase_id, ts_range) = self.phase_ids.get_entry_by_idx(phase_count - 1);
    let (start_ts, end_ts) = range_to_ts(*ts_range);
    (*phase_id, start_ts, end_ts)
}

// Description: Sort the Phases of a Launch by timestamp in ascending order.
fun sort_phases<T: key + store>(self: &mut Launch<T>) {
    // Extract phase IDs and time ranges as vectors, and quicksort them.
    let (mut phase_ids, mut ts_ranges) = self.phase_ids.into_keys_values();
    quicksort(&mut ts_ranges, &mut phase_ids, 0, self.phase_ids.size() - 1);
    // Overwrite launch phases with the sorted vectors.
    self.phase_ids = vec_map::from_keys_values(phase_ids, ts_ranges);
}

//=== Assertions ===

// Description: Assert that the Launch has not started yet.
fun assert_not_started<T: key + store>(self: &Launch<T>, clock: &Clock) {
    let (_, ts_range) = self.phase_ids.get_entry_by_idx(0);
    let (start_ts, _) = range_to_ts(*ts_range);
    assert!(clock.timestamp_ms() < start_ts, ELaunchAlreadyStarted);
}
