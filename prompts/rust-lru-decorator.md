# Prompt: decorator-style LRU cache in one Rust file

Paste the block below, then compile the answer and feed any `rustc` errors back
until it builds. Measured on this deployment (RX 7900 XT, `IQ3_XXS`, 200K
context, the defaults in `strata-wrapper.sh`):

| Workflow | Compiled | Tests passed |
| --- | --- | --- |
| One-line prompt ("write a single rust file with a decorator-style LRU cache") | 1 / 5 | 1 / 5 |
| Prompt below, one sample | 1 / 5 | 1 / 5 |
| Prompt below + one `rustc` error-feedback round | **5 / 5** | **5 / 5** |

The first pass gets the design right (all five samples had the `Lru` struct, the
`cached_fn!` macro, `thread_local!`, `peek`, `Rc<RefCell<..>>` and the
`AtomicUsize` test) but slips on ownership (`E0382`: moving `prev`/`key` out of a
node) or on macro fragment rules. Feeding the compiler errors back fixes those
in one round; a sample with a broken macro pattern may need two.

Acceptance: `rustc --edition 2021 --test file.rs` builds and all four tests pass.

---

Write a single Rust file (edition 2021, standard library only, no external
crates) that provides a Python-style `@lru_cache` decorator for functions,
implemented with a macro.

Requirements:

1. A generic `pub struct Lru<K: Clone + Eq + Hash, V>` with:
   - `new(capacity: usize)` that panics if capacity < 1;
   - O(1) `get(&mut self, key: &K) -> Option<&V>` that marks the key most-recently-used;
   - `peek(&self, key: &K) -> Option<&V>` that does not change recency;
   - `put(&mut self, key: K, value: V)` that updates in place (refreshing
     recency) or inserts, evicting the least-recently-used entry when full;
   - `len(&self) -> usize`.
   Internally use a `HashMap<K, V>` plus a doubly linked list of
   `Rc<RefCell<Node<K>>>` for recency, with a
   `HashMap<K, Rc<RefCell<Node<K>>>>` index; head is most-recently-used and
   tail is least-recently-used.

2. A `macro_rules! cached_fn!` used exactly like:

       cached_fn! {
           cache: FIB_CACHE,
           capacity: 128,
           fn fib(n: u64) -> u64 { ... }
       }

   It must keep the function's name, visibility and attributes, declare a
   `thread_local!` static `$cache: RefCell<Lru<(argument types,), ReturnType>>`,
   build the cache key from cloned arguments, return a cached clone on a hit,
   and on a miss compute the body OUTSIDE the RefCell borrow (so recursive calls
   can re-enter the cache) and then store the result. It must accept zero or more
   arguments, with an optional trailing comma.

3. Examples: `fib(u64) -> u64` and `dist((i64, i64), (i64, i64)) -> i64`, plus a
   `main()` that calls them, prints results, and prints
   `FIB_CACHE.with(|c| c.borrow().len())`.

4. A `#[cfg(test)] mod tests` with four tests: LRU eviction order, updating a key
   refreshes its recency, `peek` does not refresh recency, and the decorated
   function's body runs only on a cache miss (use an `AtomicUsize` counter).

The file must compile with `rustc --edition 2021 --test` and the tests must pass.
Return only the Rust file.
