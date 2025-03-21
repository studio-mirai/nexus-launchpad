module nexus_launchpad::quicksort;

public fun quicksort<T>(v1: &mut vector<u128>, v2: &mut vector<T>, low: u64, high: u64) {
    assert!(high < vector::length(v1), 1);
    assert!(vector::length(v1) == vector::length(v2), 2);

    if (low < high) {
        let pivot_index = partition(v1, v2, low, high);

        if (pivot_index > 0) {
            quicksort(v1, v2, low, pivot_index - 1);
        } else {
            quicksort(v1, v2, pivot_index + 1, high);
        }
    }
}

fun partition<T>(v1: &mut vector<u128>, v2: &mut vector<T>, low: u64, high: u64): u64 {
    let pivot = *vector::borrow(v1, high);

    let mut i = low;
    let mut j = low;

    while (j < high) {
        if (v1[j] < pivot) {
            v1.swap(i, j);
            v2.swap(i, j);
            i = i + 1;
        };
        j = j + 1;
    };

    v1.swap(i, high);
    v2.swap(i, high);

    i
}

#[test]
fun test_quicksort() {
    use std::debug::print;
    let mut v1 = vector[3, 1, 2]; // Sorting key
    let mut v2 = vector[b"C".to_string(), b"A".to_string(), b"B".to_string()]; // Follows v1's sorting order

    quicksort(&mut v1, &mut v2, 0, 2);

    print(&v1); // Expect: [1, 2, 3]
    print(&v2); // Expect: ["A", "B", "C"]
}
