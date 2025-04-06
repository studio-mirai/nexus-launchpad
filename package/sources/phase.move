module nexus_launchpad::phase;

use nexus_launchpad::launch::{Launch, LaunchOperatorCap};
use std::string::String;
use std::type_name::{Self, TypeName};
use sui::clock::Clock;
use sui::event::emit;
use sui::package;
use sui::table::{Self, Table};
use sui::vec_map::{Self, VecMap};

public struct PHASE has drop {}

public struct Phase<phantom T: key + store> has key {
    id: UID,
    // The kind of phase.
    kind: PhaseKind,
    // The state of the phase.
    state: PhaseState,
    // The ID of the launch that the phase belongs to.
    launch_id: ID,
    // Name of the phase.
    name: Option<String>,
    // Description of the phase.
    description: Option<String>,
    // Whether the minter can mint multiple items at once.
    is_allow_bulk_mint: bool,
    // The maximum number of mints that can be made by a single address.
    max_mint_count_addr: u64,
    // The maximum number of mints that can be made by in the phase.
    max_mint_count_phase: u64,
    // The current mint count for the phase._
    current_mint_count: u64,
    // The number of mints that have been made by each address.
    participants: Table<address, u64>,
    // The available payment options for the phase.
    payment_types: VecMap<TypeName, u64>,
}

public struct SchedulePhasePromise {
    phase_id: ID,
}

public enum PhaseKind has copy, drop, store {
    PUBLIC,
    WHITELIST { count: u64 },
}

public enum PhaseState has copy, drop, store {
    CREATED,
    // If whitelist count is greater than 0, the phase is treated as a whitelist phase.
    SCHEDULED { start_ts: u64, end_ts: u64 },
}

//=== Events ===

public struct PhaseCreatedEvent has copy, drop, store {
    phase_id: ID,
    name: Option<String>,
    description: Option<String>,
    is_allow_bulk_mint: bool,
    max_mint_count_addr: u64,
    max_mint_count_phase: u64,
}

public struct PhaseDestroyedEvent has copy, drop, store {
    launch_id: ID,
    phase_id: ID,
}

public struct PhaseScheduledEvent has copy, drop, store {
    launch_id: ID,
    phase_id: ID,
    start_ts: u64,
    end_ts: u64,
}

public struct PaymentOptionAddedEvent has copy, drop, store {
    phase_id: ID,
    payment_type: TypeName,
    payment_value: u64,
}

public struct PaymentOptionRemovedEvent has copy, drop, store {
    phase_id: ID,
    payment_type: TypeName,
}

//=== Errors ===

const EInvalidLaunch: u64 = 200;
const EPhaseAlreadyStarted: u64 = 201;
const EInvalidPhaseState: u64 = 202;
const EPhaseIsActive: u64 = 203;
const ENoPaymentOptions: u64 = 204;
const ENotWhitelistPhase: u64 = 205;
const EAlreadyPublicPhase: u64 = 206;
const EInvalidSchedulePhasePromise: u64 = 207;
const EInvalidReschedule: u64 = 208;
const EInvalidMaxMintCount: u64 = 209;
const EInvalidMaxMintAllocation: u64 = 210;
const EPhaseMaxCountExceedsLaunchSupply: u64 = 211;

//=== Init Function ===

fun init(otw: PHASE, ctx: &mut TxContext) {
    let publisher = package::claim(otw, ctx);
    transfer::public_transfer(publisher, ctx.sender());
}

//=== Public Functions ===

// Create a new phase with the given parameters.
public fun new<T: key + store>(
    cap: &LaunchOperatorCap,
    kind: PhaseKind,
    name: Option<String>,
    description: Option<String>,
    max_mint_count_addr: u64,
    max_mint_count_phase: u64,
    is_allow_bulk_mint: bool,
    ctx: &mut TxContext,
): (Phase<T>, SchedulePhasePromise) {
    assert!(max_mint_count_phase > 0, EInvalidMaxMintCount);
    assert!(max_mint_count_addr > 0, EInvalidMaxMintAllocation);
    assert!(max_mint_count_addr < max_mint_count_phase, EInvalidMaxMintAllocation);

    let phase = Phase<T> {
        id: object::new(ctx),
        kind: kind,
        state: PhaseState::CREATED,
        launch_id: cap.launch_id(),
        name: name,
        description: description,
        is_allow_bulk_mint: is_allow_bulk_mint,
        max_mint_count_addr: max_mint_count_addr,
        max_mint_count_phase: max_mint_count_phase,
        current_mint_count: 0,
        participants: table::new(ctx),
        payment_types: vec_map::empty(),
    };

    let promise = SchedulePhasePromise {
        phase_id: phase.id(),
    };

    emit(PhaseCreatedEvent {
        phase_id: phase.id(),
        name: phase.name,
        description: phase.description,
        is_allow_bulk_mint: phase.is_allow_bulk_mint,
        max_mint_count_addr: phase.max_mint_count_addr,
        max_mint_count_phase: phase.max_mint_count_phase,
    });

    (phase, promise)
}

public fun new_phase_kind_public(): PhaseKind {
    PhaseKind::PUBLIC
}

public fun new_phase_kind_whitelist(): PhaseKind {
    PhaseKind::WHITELIST { count: 0 }
}

// Destroy a phase, and unregister it from the launch.
// @ux: UX should warn users that this action will invalidate whitelist tickets issued for the phase.
public fun destroy<T: key + store>(
    self: Phase<T>,
    cap: &LaunchOperatorCap,
    launch: &mut Launch<T>,
    clock: &Clock,
) {
    cap.authorize(self.launch_id());

    match (self.state) {
        PhaseState::SCHEDULED { .. } => {
            // Assert the phase's registered launch ID is the same as the given launch's ID.
            assert!(self.launch_id() == launch.id(), EInvalidLaunch);

            emit(PhaseDestroyedEvent {
                launch_id: launch.id(),
                phase_id: self.id(),
            });

            // Assert the phase is not active.
            self.assert_not_active(clock);

            // Unschedule the phase from the launch.
            launch.unschedule_phase(self.id());

            let Phase {
                id,
                participants,
                payment_types,
                ..,
            } = self;

            id.delete();
            participants.drop();
            payment_types.into_keys_values();
        },
        _ => abort EInvalidPhaseState,
    };
}

public fun schedule<T: key + store>(
    mut self: Phase<T>,
    promise: SchedulePhasePromise,
    cap: &LaunchOperatorCap,
    launch: &mut Launch<T>,
    start_ts: u64,
    end_ts: u64,
    clock: &Clock,
) {
    // Asser the LaunchOperatorCap matches the provided Launch.
    cap.authorize(launch.id());

    // Assert the SchedulePhasePromise matches the provided Phase.
    assert!(self.id() == promise.phase_id, EInvalidSchedulePhasePromise);

    // Assert the start/end timestamps are valid.
    assert_valid_ts_range(start_ts, end_ts, clock);

    assert!(self.max_mint_count_phase <= launch.total_supply(), EPhaseMaxCountExceedsLaunchSupply);

    match (self.state) {
        PhaseState::CREATED => {
            // Assert the Phase has at least one payment option.
            assert!(!self.payment_types.is_empty(), ENoPaymentOptions);

            launch.schedule_phase(self.id(), start_ts, end_ts);

            emit(PhaseScheduledEvent {
                launch_id: self.launch_id(),
                phase_id: self.id(),
                start_ts: start_ts,
                end_ts: end_ts,
            });

            self.state =
                PhaseState::SCHEDULED {
                    start_ts: start_ts,
                    end_ts: end_ts,
                };

            let SchedulePhasePromise { .. } = promise;

            transfer::share_object(self);
        },
        _ => abort EInvalidPhaseState,
    }
}

public fun reschedule<T: key + store>(
    self: &mut Phase<T>,
    cap: &LaunchOperatorCap,
    launch: &mut Launch<T>,
    new_start_ts: u64,
    new_end_ts: u64,
    clock: &Clock,
) {
    // Verify the LaunchOperatorCap matches the given Launch.
    cap.authorize(launch.id());

    // Assert the new start/end timestamps are valid.
    assert_valid_ts_range(new_start_ts, new_end_ts, clock);

    match (self.state) {
        PhaseState::SCHEDULED { start_ts, end_ts } => {
            // Verify the LaunchOperatorCap matches the Phase's registered Launch ID.
            cap.authorize(self.launch_id());
            // Assert the new start/end timestamps are different from the existing timestamps.
            assert!(start_ts != new_start_ts || end_ts != new_end_ts, EInvalidReschedule);
            // Reschedule the phase from the launch.
            launch.schedule_phase(self.id(), new_start_ts, new_end_ts);
            // Update the Phase's state.
            self.state =
                PhaseState::SCHEDULED {
                    start_ts: new_start_ts,
                    end_ts: new_end_ts,
                };
        },
        _ => abort EInvalidPhaseState,
    }
}

public fun add_payment_type<T: key + store, C>(
    self: &mut Phase<T>,
    cap: &LaunchOperatorCap,
    value: u64,
    clock: &Clock,
) {
    match (self.state) {
        PhaseState::CREATED => {
            cap.authorize(self.launch_id());
        },
        PhaseState::SCHEDULED { .. } => {
            // Verify the LaunchOperatorCap matches the Phase's registered Launch ID.
            cap.authorize(self.launch_id());
            // Assert the Phase has not started.
            self.assert_not_started(clock);
        },
    };

    emit(PaymentOptionAddedEvent {
        phase_id: self.id(),
        payment_type: type_name::get<C>(),
        payment_value: value,
    });

    // Add the payment option to the Phase.
    self.payment_types.insert(type_name::get<C>(), value);
}

// Remove a payment option from the `Phase`.
// This can only be done before the `Phase` has started.
public fun remove_payment_type<T: key + store, C>(
    self: &mut Phase<T>,
    cap: &LaunchOperatorCap,
    clock: &Clock,
) {
    match (self.state) {
        PhaseState::CREATED => {
            cap.authorize(self.launch_id());
        },
        PhaseState::SCHEDULED { .. } => {
            // Verify the LaunchOperatorCap matches the Phase's registered Launch ID.
            cap.authorize(self.launch_id());
            // Assert the Phase has not started.
            self.assert_not_started(clock);
        },
    };

    emit(PaymentOptionRemovedEvent {
        phase_id: self.id(),
        payment_type: type_name::get<C>(),
    });

    // Remove the payment option from the Phase.
    self.payment_types.remove(&type_name::get<C>());
}

public fun set_is_allow_bulk_mint<T: key + store>(
    self: &mut Phase<T>,
    cap: &LaunchOperatorCap,
    is_allow_bulk_mint: bool,
    clock: &Clock,
) {
    match (self.state) {
        PhaseState::SCHEDULED { .. } => {
            // Verify the LaunchOperatorCap matches the Phase's registered Launch ID.
            cap.authorize(self.launch_id());
            // Assert the Phase has not started.
            self.assert_not_started(clock);
            // Update the Phase's `is_allow_bulk_mint` value.
            self.is_allow_bulk_mint = is_allow_bulk_mint;
        },
        _ => abort EInvalidPhaseState,
    }
}

public fun set_max_mint_count_addr<T: key + store>(
    self: &mut Phase<T>,
    cap: &LaunchOperatorCap,
    max_mint_count_addr: u64,
    clock: &Clock,
) {
    match (self.state) {
        PhaseState::SCHEDULED { .. } => {
            // Verify the LaunchOperatorCap matches the Phase's registered Launch ID.
            cap.authorize(self.launch_id());
            // Assert the phase has not started.
            self.assert_not_started(clock);
            // Update the Phase's `max_mint_count_addr` value.
            self.max_mint_count_addr = max_mint_count_addr;
        },
        _ => abort EInvalidPhaseState,
    }
}

public fun set_max_mint_count_phase<T: key + store>(
    self: &mut Phase<T>,
    cap: &LaunchOperatorCap,
    max_mint_count_phase: u64,
    clock: &Clock,
) {
    match (self.state) {
        PhaseState::SCHEDULED { .. } => {
            // Verify the LaunchOperatorCap matches the Phase's registered Launch ID.
            cap.authorize(self.launch_id());
            // Assert the Phase has not started.
            self.assert_not_started(clock);
            // Update the Phase's `max_mint_count_phase` value.
            self.max_mint_count_phase = max_mint_count_phase;
        },
        _ => abort EInvalidPhaseState,
    }
}

public fun set_phase_kind<T: key + store>(self: &mut Phase<T>, kind: PhaseKind) {
    match (self.kind) {
        PhaseKind::WHITELIST { .. } => {
            match (kind) {
                PhaseKind::PUBLIC => { self.kind = kind; },
                _ => abort EAlreadyPublicPhase,
            }
        },
        PhaseKind::PUBLIC => {
            match (kind) {
                PhaseKind::WHITELIST { .. } => { self.kind = kind; },
                _ => abort EAlreadyPublicPhase,
            }
        },
    }
}

// Returns the number of mints in the current phase for the given address.
public(package) fun participant_mint_count<T: key + store>(
    self: &mut Phase<T>,
    addr: address,
): u64 {
    if (!self.participants.contains(addr)) {
        self.participants.add(addr, 0);
    };

    *self.participants.borrow(addr)
}

public(package) fun increment_current_mint_count<T: key + store>(self: &mut Phase<T>) {
    self.current_mint_count = self.current_mint_count + 1;
}

public(package) fun increment_participant_mint_count<T: key + store>(
    self: &mut Phase<T>,
    addr: address,
) {
    if (!self.participants.contains(addr)) {
        self.participants.add(addr, 0);
    };

    let count = self.participants.borrow_mut(addr);
    *count = *count + 1;
}

public(package) fun increment_whitelist_count<T: key + store>(self: &mut Phase<T>) {
    match (&mut self.kind) {
        PhaseKind::WHITELIST { count } => {
            *count = *count + 1;
        },
        _ => abort ENotWhitelistPhase,
    }
}
//=== View Functions ===

public fun id<T: key + store>(self: &Phase<T>): ID {
    self.id.to_inner()
}

public fun current_mint_count<T: key + store>(self: &Phase<T>): u64 {
    self.current_mint_count
}

public fun launch_id<T: key + store>(self: &Phase<T>): ID {
    self.launch_id
}

public fun name<T: key + store>(self: &Phase<T>): Option<String> {
    self.name
}

public fun description<T: key + store>(self: &Phase<T>): Option<String> {
    self.description
}

public fun is_allow_bulk_mint<T: key + store>(self: &Phase<T>): bool {
    self.is_allow_bulk_mint
}

public fun max_mint_count_addr<T: key + store>(self: &Phase<T>): u64 {
    self.max_mint_count_addr
}

public fun max_mint_count_phase<T: key + store>(self: &Phase<T>): u64 {
    self.max_mint_count_phase
}

public fun payment_types<T: key + store>(self: &Phase<T>): &VecMap<TypeName, u64> {
    &self.payment_types
}

public(package) fun assert_is_whitelist<T: key + store>(self: &Phase<T>) {
    match (self.kind) {
        PhaseKind::WHITELIST { .. } => {},
        _ => abort ENotWhitelistPhase,
    }
}

fun assert_valid_ts_range(start_ts: u64, end_ts: u64, clock: &Clock) {
    // Assert the start timestamp is in the future.
    assert!(start_ts > clock.timestamp_ms(), 1);
    // Assert the end timestamp is after the start timestamp.
    assert!(end_ts > start_ts, 2);
}

fun assert_not_active<T: key + store>(self: &Phase<T>, clock: &Clock) {
    match (self.state) {
        PhaseState::SCHEDULED { start_ts, end_ts, .. } => {
            assert!(
                clock.timestamp_ms() < start_ts || clock.timestamp_ms() > end_ts,
                EPhaseIsActive,
            );
        },
        _ => abort EInvalidPhaseState,
    }
}

fun assert_not_started<T: key + store>(self: &Phase<T>, clock: &Clock) {
    match (self.state) {
        PhaseState::SCHEDULED { start_ts, .. } => {
            assert!(clock.timestamp_ms() < start_ts, EPhaseAlreadyStarted);
        },
        _ => abort EInvalidPhaseState,
    }
}
