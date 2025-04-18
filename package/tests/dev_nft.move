#[test_only]
module nexus_launchpad::dev_nft;

// === imports ===

use std::string::{String};
use sui::display::{Self};
use sui::package::{Self};

// === structs ===

public struct DEV_NFT has drop {}

public struct DevNft has key, store {
    id: UID,
    name: String,
    number: u64,
    image_url: String,
}

// === public-mutative functions ===

public fun new_dev_nft(
    name: vector<u8>,
    number: u64,
    image_url: vector<u8>,
    ctx: &mut TxContext,
): DevNft {
    return DevNft {
        id: object::new(ctx),
        name: name.to_string(),
        number: number,
        image_url: image_url.to_string(),
    }
}

// === initialization ===

fun init(otw: DEV_NFT, ctx: &mut TxContext)
{
    let publisher = package::claim(otw, ctx);

    let mut display = display::new<DevNft>(&publisher, ctx);
    display.add(b"name".to_string(), b"{name} #{number}".to_string());
    display.add(b"image_url".to_string(), b"{image_url}".to_string());
    display::update_version(&mut display);

    transfer::public_transfer(publisher, ctx.sender());
    transfer::public_transfer(display, ctx.sender());
}

// === test functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(DEV_NFT {}, ctx);
}
