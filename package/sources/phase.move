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
    // Start timestamp of the phase.
    start_ts: u64,
    // End timestamp of the phase.
    end_ts: u64,
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

public struct RegisterPhasePromise {
    phase_id: ID,
}

public enum PhaseKind has copy, drop, store {
    PUBLIC,
    WHITELIST { count: u64 },
}

public enum PhaseState has copy, drop, store {
    CREATED,
    READY,
    ENDED,
}

//=== Constants ===

const MAX_PAYMENT_TYPE_COUNT: u64 = 50;

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

public struct PhaseRegisteredEvent has copy, drop, store {
    launch_id: ID,
    phase_id: ID,
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

const EExceedsLaunchSupply: u64 = 20001;
const EExceedsMaxPaymentTypeCount: u64 = 20002;
const EInvalidMaxAddressMint: u64 = 20003;
const EInvalidMaxPhaseMintCount: u64 = 20004;
const EInvalidPhaseState: u64 = 20005;
const EInvalidRegisterPhasePromise: u64 = 20006;
const EMaxPhaseMintCountTooLow: u64 = 20007;
const ENoPaymentOptions: u64 = 20008;
const ENotWhitelistPhase: u64 = 20009;
const EPhaseEnded: u64 = 20010;
const EPhaseMaxCountExceedsLaunchSupply: u64 = 20011;
const EPhaseNotEnded: u64 = 20012;
const EPhaseNotMintable: u64 = 20013;
const EPhaseNotStarted: u64 = 20014;
const EStartTsAfterEndTs: u64 = 20015;
const EStartTsBeforeEndTs: u64 = 20016;
const ETimestampNotInFuture: u64 = 20017;
const ENotPublicPhase: u64 = 20018;
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
    start_ts: u64,
    end_ts: u64,
    max_mint_count_addr: u64,
    max_mint_count_phase: u64,
    is_allow_bulk_mint: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): (Phase<T>, RegisterPhasePromise) {
    // Assert the max mint count for the phase is greater than 0.
    assert!(max_mint_count_phase > 0, EInvalidMaxPhaseMintCount);
    // Assert the max mint count for an address is greater than 0.
    assert!(max_mint_count_addr > 0, EInvalidMaxAddressMint);
    // Assert the max mint count for an address does not exceed the max mint count for the phase.
    assert!(max_mint_count_addr <= max_mint_count_phase, EInvalidMaxAddressMint);
    // Assert the start/end timestamps are valid.
    assert_valid_ts_range(start_ts, end_ts, clock);

    let phase = Phase<T> {
        id: object::new(ctx),
        kind: kind,
        state: PhaseState::CREATED,
        launch_id: cap.launch_id(),
        name: name,
        description: description,
        start_ts: start_ts,
        end_ts: end_ts,
        is_allow_bulk_mint: is_allow_bulk_mint,
        max_mint_count_addr: max_mint_count_addr,
        max_mint_count_phase: max_mint_count_phase,
        current_mint_count: 0,
        participants: table::new(ctx),
        payment_types: vec_map::empty(),
    };

    let promise = RegisterPhasePromise {
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

public fun register<T: key + store>(
    self: Phase<T>,
    promise: RegisterPhasePromise,
    cap: &LaunchOperatorCap,
    launch: &mut Launch<T>,
) {
    // Assert the LaunchOperatorCap matches the provided Launch.
    cap.authorize(launch.id());
    // Assert the RegisterPhasePromise matches the provided Phase.
    assert!(self.id() == promise.phase_id, EInvalidRegisterPhasePromise);
    // Assert the Phase's mint count doesn't exceed the Launch's available supply.
    assert!(self.max_mint_count_phase <= launch.supply(), EPhaseMaxCountExceedsLaunchSupply);
    // Assert the Phase has at least one payment option.
    assert!(!self.payment_types.is_empty(), ENoPaymentOptions);
    // Register the Phase with the Launch.
    launch.register_phase(self.id());
    // Destroy the RegisterPhasePromise hot potato.
    let RegisterPhasePromise { .. } = promise;
    // Emit PhaseRegisteredEvent.
    emit(PhaseRegisteredEvent {
        launch_id: launch.id(),
        phase_id: self.id(),
    });
    // Turn the Phase into a shared object.
    transfer::share_object(self);
}

// Destroy a Phase.
public fun destroy<T: key + store>(
    self: Phase<T>,
    launch: &mut Launch<T>,
    cap: &LaunchOperatorCap,
) {
    // Verify the LaunchOperatorCap matches the Phase's registered Launch ID.
    cap.authorize(self.launch_id());

    match (self.state) {
        PhaseState::ENDED => {
            // Unregister the Phase from the Launch.
            launch.unregister_phase(self.id());
            // Emit PhaseDestroyedEvent.
            emit(PhaseDestroyedEvent {
                launch_id: self.launch_id(),
                phase_id: self.id(),
            });
            // Destroy the Phase.
            let Phase { id, participants, .. } = self;
            id.delete();
            participants.drop();
        },
        _ => abort EInvalidPhaseState,
    };
}

// Add a payment type to the Phase.
public fun add_payment_type<T: key + store, C>(
    self: &mut Phase<T>,
    cap: &LaunchOperatorCap,
    value: u64,
) {
    // Verify the LaunchOperatorCap matches the Phase's registered Launch ID.
    cap.authorize(self.launch_id());
    // Assert the Phase has less than the maximum number of payment options.
    assert!(self.payment_types.size() < MAX_PAYMENT_TYPE_COUNT, EExceedsMaxPaymentTypeCount);
    // Add the payment option to the Phase.
    self.payment_types.insert(type_name::get<C>(), value);
    // Emit PaymentOptionAddedEvent.
    emit(PaymentOptionAddedEvent {
        phase_id: self.id(),
        payment_type: type_name::get<C>(),
        payment_value: value,
    });
}

// Remove a payment option from the Phase.
public fun remove_payment_type<T: key + store, C>(self: &mut Phase<T>, cap: &LaunchOperatorCap) {
    // Verify the LaunchOperatorCap matches the Phase's registered Launch ID.
    cap.authorize(self.launch_id());
    // Assert the Phase has more than one payment option,
    // so that if one payment option is removed, there will still be at least one payment option.
    assert!(self.payment_types.size() > 1, ENoPaymentOptions);
    // Remove the payment option from the Phase.
    self.payment_types.remove(&type_name::get<C>());
    // Emit PaymentOptionRemovedEvent.
    emit(PaymentOptionRemovedEvent {
        phase_id: self.id(),
        payment_type: type_name::get<C>(),
    });
}

// Set the name of the Phase.
public fun set_name<T: key + store>(self: &mut Phase<T>, cap: &LaunchOperatorCap, name: String) {
    cap.authorize(self.launch_id());
    self.name.swap_or_fill(name);
}

// Set the description of the Phase.
public fun set_description<T: key + store>(
    self: &mut Phase<T>,
    cap: &LaunchOperatorCap,
    description: String,
) {
    cap.authorize(self.launch_id());
    self.description.swap_or_fill(description);
}

// Set the `is_allow_bulk_mint` value for the Phase.
// If true, minters will be able to mint multiple items in a single transaction.
public fun set_is_allow_bulk_mint<T: key + store>(
    self: &mut Phase<T>,
    cap: &LaunchOperatorCap,
    is_allow_bulk_mint: bool,
) {
    // Verify the LaunchOperatorCap matches the Phase's registered Launch ID.
    cap.authorize(self.launch_id());
    // Update the Phase's `is_allow_bulk_mint` value.
    self.is_allow_bulk_mint = is_allow_bulk_mint;
}

// Set the maximum number of mints that can be made by a single address in the Phase.
public fun set_max_mint_count_addr<T: key + store>(
    self: &mut Phase<T>,
    cap: &LaunchOperatorCap,
    max_mint_count_addr: u64,
) {
    // Verify the LaunchOperatorCap matches the Phase's registered Launch ID.
    cap.authorize(self.launch_id());
    // Assert the value is greater than the current max mint count for an address.
    assert!(max_mint_count_addr > self.max_mint_count_addr, EInvalidMaxAddressMint);
    assert!(max_mint_count_addr <= self.max_mint_count_phase, EInvalidMaxAddressMint);
    self.max_mint_count_addr = max_mint_count_addr;
}

// Set the maximum number of mints that can be made in the Phase.
public fun set_max_mint_count_phase<T: key + store>(
    self: &mut Phase<T>,
    cap: &LaunchOperatorCap,
    max_mint_count_phase: u64,
    launch: &mut Launch<T>,
) {
    // Verify the LaunchOperatorCap matches the Phase's registered Launch ID.
    cap.authorize(self.launch_id());
    // Verify the LaunchOperatorCap matches the provided Launch.
    cap.authorize(launch.id());
    // Assert the value doesn't exceed the launch's total supply.
    assert!(max_mint_count_phase <= launch.items().length(), EExceedsLaunchSupply);
    // Assert that the value is greater than the current max phase mint count.
    assert!(max_mint_count_phase > self.max_mint_count_phase, EMaxPhaseMintCountTooLow);
    // Assert the value is greater than the current max mint count for an address.
    assert!(max_mint_count_phase > self.max_mint_count_addr, EMaxPhaseMintCountTooLow);
    // Update the Phase's `max_mint_count_phase` value.
    self.max_mint_count_phase = max_mint_count_phase;
}

// Set the start timestamp for the Phase.
// Requires the Phase to be in READY state.
public fun set_start_ts<T: key + store>(
    self: &mut Phase<T>,
    cap: &LaunchOperatorCap,
    start_ts: u64,
    clock: &Clock,
) {
    cap.authorize(self.launch_id());
    // Assert the start timestamp is in the future.
    assert!(start_ts > clock.timestamp_ms(), ETimestampNotInFuture);

    match (self.state) {
        PhaseState::READY => {
            assert!(self.start_ts < self.end_ts, EStartTsAfterEndTs);
            self.state = PhaseState::READY;
        },
        _ => abort EInvalidPhaseState,
    }
}

// Set the end timestamp for the Phase.
// Requires the Phase to be in READY state.
public fun set_end_ts<T: key + store>(
    self: &mut Phase<T>,
    cap: &LaunchOperatorCap,
    end_ts: u64,
    clock: &Clock,
) {
    cap.authorize(self.launch_id());
    // Assert the end timestamp is in the future.
    assert!(end_ts > clock.timestamp_ms(), ETimestampNotInFuture);

    match (self.state) {
        PhaseState::READY => {
            assert!(self.end_ts > self.start_ts, EStartTsBeforeEndTs);
            self.state = PhaseState::READY;
        },
        _ => abort EInvalidPhaseState,
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

public(package) fun increment_mint_count<T: key + store>(self: &mut Phase<T>, ctx: &TxContext) {
    // Create a new participant entry if the minter's address is not in the participants table.
    if (!self.participants.contains(ctx.sender())) {
        self.participants.add(ctx.sender(), 0);
    };
    // Increment the mint count for the minter's address.
    let count = self.participants.borrow_mut(ctx.sender());
    *count = *count + 1;
    // Increment the current mint count for the phase.
    self.current_mint_count = self.current_mint_count + 1;
}

public(package) fun increment_whitelist_count<T: key + store>(self: &mut Phase<T>) {
    match (&mut self.kind) {
        PhaseKind::WHITELIST { count } => {
            *count = *count + 1;
        },
        _ => abort ENotWhitelistPhase,
    }
}

// Returns the remaining number of mints that can be made in the Phase.
public(package) fun remaining_mint_count<T: key + store>(self: &Phase<T>): u64 {
    self.max_mint_count_phase - self.current_mint_count
}

// Transition a Phase from READY state to READY state.
public(package) fun set_ready_state<T: key + store>(self: &mut Phase<T>, clock: &Clock) {
    match (self.state) {
        PhaseState::READY => {
            assert!(self.start_ts >= clock.timestamp_ms(), EPhaseNotStarted);
            assert!(clock.timestamp_ms() < self.end_ts, EPhaseEnded);
            self.state = PhaseState::READY;
        },
        _ => abort EInvalidPhaseState,
    }
}

// Transition a Phase from READY state to ENDED state.
public(package) fun set_ended_state<T: key + store>(self: &mut Phase<T>, clock: &Clock) {
    match (self.state) {
        PhaseState::READY => {
            assert!(clock.timestamp_ms() > self.end_ts, EPhaseNotEnded);
            self.state = PhaseState::ENDED;
        },
        _ => abort EInvalidPhaseState,
    }
}

// Returns true if the Phase has PUBLIC kind.
public fun is_public_kind<T: key + store>(self: &Phase<T>): bool {
    match (self.kind) {
        PhaseKind::PUBLIC => true,
        _ => false,
    }
}

// Returns true if the Phase has WHITELIST kind.
public fun is_whitelist_kind<T: key + store>(self: &Phase<T>): bool {
    match (self.kind) {
        PhaseKind::WHITELIST { .. } => true,
        _ => false,
    }
}

// Returns true if the Phase is in CREATED state.
public fun is_created_state<T: key + store>(self: &Phase<T>): bool {
    match (self.state) {
        PhaseState::CREATED => true,
        _ => false,
    }
}

// Returns true if the Phase is in READY state.
public fun is_ready_state<T: key + store>(self: &Phase<T>): bool {
    match (self.state) {
        PhaseState::READY => true,
        _ => false,
    }
}

// Returns true if the Phase is in ENDED state.
public fun is_ended_state<T: key + store>(self: &Phase<T>): bool {
    match (self.state) {
        PhaseState::ENDED => true,
        _ => false,
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

fun assert_valid_ts_range(start_ts: u64, end_ts: u64, clock: &Clock) {
    // Assert the start timestamp is in the future.
    assert!(start_ts > clock.timestamp_ms(), 1);
    // Assert the end timestamp is after the start timestamp.
    assert!(end_ts > start_ts, 2);
}

//=== Assertions ===

public fun assert_is_mintable<T: key + store>(self: &Phase<T>, clock: &Clock) {
    match (self.state) {
        PhaseState::READY => {
            assert!(
                clock.timestamp_ms() >= self.start_ts && clock.timestamp_ms() < self.end_ts,
                EPhaseNotMintable,
            );
        },
        _ => abort EPhaseNotMintable,
    }
}

public fun assert_is_public<T: key + store>(self: &Phase<T>) {
    assert!(self.is_public_kind(), ENotPublicPhase);
}

public fun assert_is_whitelist<T: key + store>(self: &Phase<T>) {
    assert!(self.is_whitelist_kind(), ENotWhitelistPhase);
}
