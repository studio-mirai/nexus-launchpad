module nexus_launchpad::whitelist;

use nexus_launchpad::launch::{Launch, LaunchOperatorCap};
use nexus_launchpad::phase::Phase;
use std::type_name::{Self, TypeName};
use sui::display;
use sui::event::emit;
use sui::package;

//=== Structs ===

public struct WHITELIST has drop {}

public struct Whitelist has key, store {
    id: UID,
    item_type: TypeName,
    launch_id: ID,
    phase_id: ID,
}

//=== Events ===

public struct WhitelistCreatedEvent has copy, drop {
    whitelist_id: ID,
    launch_id: ID,
    phase_id: ID,
}

//=== Init Function ===

fun init(otw: WHITELIST, ctx: &mut TxContext) {
    let publisher = package::claim(otw, ctx);

    let mut display = display::new<Whitelist>(&publisher, ctx);
    display.add(b"item_type".to_string(), b"{item_type}".to_string());
    display.add(b"launch_id".to_string(), b"{launch_id}".to_string());
    display.add(b"phase_id".to_string(), b"{phase_id}".to_string());
    display.add(
        b"image".to_string(),
        b"https://admin.anima.nexus/api/wl_image/{launch_id}/{phase_id}".to_string(),
    );
    display.update_version();

    transfer::public_transfer(display, ctx.sender());
    transfer::public_transfer(publisher, ctx.sender());
}

//=== Public Functions ===

public fun new<T: key + store>(
    cap: &LaunchOperatorCap,
    launch: &mut Launch<T>,
    phase: &mut Phase<T>,
    ctx: &mut TxContext,
): Whitelist {
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

public fun destroy(self: Whitelist) {
    let Whitelist { id, .. } = self;
    id.delete();
}

//=== View Functions ===

public fun id(self: &Whitelist): ID {
    self.id.to_inner()
}

public fun launch_id(self: &Whitelist): ID {
    self.launch_id
}

public fun phase_id(self: &Whitelist): ID {
    self.phase_id
}

//=== Private Functions ===

fun internal_new<T: key + store>(phase: &mut Phase<T>, ctx: &mut TxContext): Whitelist {
    let whitelist = Whitelist {
        id: object::new(ctx),
        launch_id: phase.launch_id(),
        phase_id: phase.id(),
        item_type: type_name::get<T>(),
    };

    emit(WhitelistCreatedEvent {
        whitelist_id: whitelist.id.to_inner(),
        launch_id: whitelist.launch_id,
        phase_id: whitelist.phase_id,
    });

    phase.increment_whitelist_count();

    whitelist
}
