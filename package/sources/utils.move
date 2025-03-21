module nexus_launchpad::utils;

public(package) fun ts_to_range(start_ts: u64, end_ts: u64): u128 {
    ((start_ts as u128) << 64) | (end_ts as u128)
}

public(package) fun range_to_ts(ts_range: u128): (u64, u64) {
    let start_ts: u64 = (ts_range >> 64) as u64;
    let end_ts: u64 = (ts_range & 0xFFFFFFFFFFFFFFFF) as u64;
    (start_ts, end_ts)
}

#[test]
fun test_ts_to_range() {
    let res = ts_to_range(1738335600000, 1738422000000);
    assert!(res == 32066631927418337635868751600000, 0);
}

#[test]
fun test_range_to_ts() {
    let (start_ts, end_ts) = range_to_ts(32066631927418337635868751600000);
    assert!(start_ts == 1738335600000, 0);
    assert!(end_ts == 1738422000000, 1);
}
