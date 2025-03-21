module launchpad::whitelist;

use launchpad::launch::{Launch, LaunchOperatorCap};
use launchpad::phase::Phase;
use sui::event::emit;
use sui::package;

//=== Structs ===

public struct WHITELIST has drop {}

public struct Whitelist<phantom T: key + store> has key, store {
    id: UID,
    launch_id: ID,
    phase_id: ID,
}

public struct WhitelistCreatedEvent has copy, drop {
    whitelist_id: ID,
    launch_id: ID,
    phase_id: ID,
}

//=== Init Function ===

fun init(otw: WHITELIST, ctx: &mut TxContext) {
    let publisher = package::claim(otw, ctx);
    transfer::public_transfer(publisher, ctx.sender());
}

//=== Public Functions ===

public fun new<T: key + store>(
    cap: &LaunchOperatorCap,
    launch: &mut Launch<T>,
    phase: &mut Phase<T>,
    ctx: &mut TxContext,
): Whitelist<T> {
    cap.authorize(launch.id());
    cap.authorize(phase.launch_id());

    let whitelist = internal_new(phase, ctx);

    whitelist
}

public fun issue_bulk<T: key + store>(
    cap: &LaunchOperatorCap,
    launch: &mut Launch<T>,
    phase: &mut Phase<T>,
    mut recipients: vector<address>,
    mut quantities: vector<u64>,
    ctx: &mut TxContext,
) {
    cap.authorize(launch.id());
    cap.authorize(phase.launch_id());

    while (!recipients.is_empty()) {
        let recipient = recipients.pop_back();
        let quantity = quantities.pop_back();
        let whitelists = vector::tabulate!(quantity, |_| internal_new(phase, ctx));
        whitelists.destroy!(|wl| transfer::public_transfer(wl, recipient));
    };

    recipients.destroy_empty();
}

public fun destroy<T: key + store>(self: Whitelist<T>) {
    let Whitelist { id, .. } = self;
    id.delete();
}

//=== View Functions ===

public fun id<T: key + store>(self: &Whitelist<T>): ID {
    self.id.to_inner()
}

public fun launch_id<T: key + store>(self: &Whitelist<T>): ID {
    self.launch_id
}

public fun phase_id<T: key + store>(self: &Whitelist<T>): ID {
    self.phase_id
}

//=== Private Functions ===

fun internal_new<T: key + store>(phase: &mut Phase<T>, ctx: &mut TxContext): Whitelist<T> {
    let whitelist = Whitelist {
        id: object::new(ctx),
        launch_id: phase.launch_id(),
        phase_id: phase.id(),
    };

    emit(WhitelistCreatedEvent {
        whitelist_id: whitelist.id.to_inner(),
        launch_id: whitelist.launch_id,
        phase_id: whitelist.phase_id,
    });

    phase.increment_whitelist_count();

    whitelist
}
