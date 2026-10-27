# Modernize lua-resty-mongol Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the driver work against MongoDB 6.0, 7.0, 8.0 and 9.0 with the documented API unchanged, in six shippable phases.

**Architecture:** A new `wire.lua` sends every request as `OP_MSG` and parses `OP_MSG` replies. `db:cmd()` and all collection methods become thin wrappers over commands (`find`, `insert`, `update`, `delete`, `getMore`, `killCursors`). BSON gets ordered documents, integer types and the missing types. Auth moves to a new `scram.lua`.

**Tech Stack:** OpenResty LuaJIT (Lua 5.1), ngx_lua cosockets, `resty.sha256`, `resty.sha1`, `resty.md5`, `resty.random`, `resty.string`, LuaJIT `ffi`. Tests: Test::Nginx (`prove -r t`) in GitHub Actions with the `mongo` Docker image.

**Spec:** `docs/superpowers/specs/2026-10-25-modernize-driver-design.md`

## Global Constraints

- Server versions: MongoDB 6.0, 7.0, 8.0, 9.0. The CI matrix uses the images `mongo:6.0`, `mongo:7.0`, `mongo:8.0`, `mongo:9.0`.
- Runtime: OpenResty LuaJIT. No C modules. Only Lua libraries that ship with OpenResty. FFI calls into the OpenSSL that OpenResty links are allowed.
- CI OpenResty version: 1.31.1.1, the current release on 2026-10-25.
- Module style follows `openresty/lua-resty-redis`: `local _M = { _VERSION = "x.y.z" }`, globals cached as locals at file top, `table.new` and `table.clear` on hot paths, and `setmetatable(obj, mt)` objects.
- Caller type bugs raise `error("bad argument ...", 2)`. Everything else returns `nil, err`.
- `luacheck` (with `std = "ngx_lua"`) and `lj-releng` must pass in CI.
- All network I/O uses cosockets. No blocking calls.
- The library writes no Lua globals. This includes `_G.pairs`, which `misc.lua` overrides today.
- Every documented call keeps its arguments and its return values. A change that a caller can see goes in `CHANGELOG.md` with its reason.
- Socket, protocol and server errors return `nil, err`. They do not raise Lua errors.
- Opcodes: the driver sends only `OP_MSG` (2013).
- `safe`: the values `nil`, `false` and `0` mean `writeConcern = {w = 0}` and a return of `-1`. Any other value means acknowledged.
- Phase 1 number rule (owner decision, Option B): a whole number that fits in int32 goes out as int32. A larger whole number that fits in int64 goes out as int64. Any other number goes out as a double. On read, an int64 above 2^53 returns as `int64_t` cdata.
- License: MIT/X11.
- Commit style: `type(scope): description`, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Test rule: if a test sends a command with more than one key through `db:cmd`, it builds the command with `bson.ordered`. This keeps the command name as the first key.

## Review Focus

1. A server that closes the socket or sends a short or invalid reply. Expected: the call returns `nil, err`, and the driver closes the socket so that `set_keepalive` cannot put a broken socket in the pool. Test: Task 3, `TEST: truncated reply`.
2. A cursor with `limit` that is not a multiple of the batch size, over more than one `getMore`. Expected: exactly `limit` documents, then `nil`. Test: Task 6, `TEST: limit across batches`.
3. Number edges: `2^31 - 1`, `2^31`, `-2^31 - 1`, `2^53 + 1` as cdata, `0.5`, `-0.0`, `1e300`, NaN. Expected: each value round trips with the type from the Task 2b rule. Test: Task 2b, `TEST: number edges`.
4. Strings with embedded `\0`, and binary data. Expected: an exact round trip for values. Keys with `\0` return `nil, err`. Test: Task 2, `TEST: nul in values`.
5. A pooled socket reused by a request that needs a different login. Expected: the README pattern with one pool name for each user works, and `get_reused_times()` lets the caller skip a second login. Test: Task 8, `TEST: pooled login reuse`.

---

## File Structure

| File | Responsibility | Phase |
|---|---|---|
| `LICENSE` | MIT/X11 text, with the original authors | 0 |
| `.github/workflows/test.yml` | CI matrix and service containers | 0, 3, 5 |
| `Makefile` | `test`, `test-auth`, `test-replset`, `test-tls` and `spec-data` targets | 0, 1, 3 |
| `t/lib/Mongol.pm` | Shared Test::Nginx setup: `$HttpConfig` and environment defaults | 0 |
| `t/api.t` (new) | One test for each documented call, with a baseline on MongoDB 4.4 | 0 |
| `t/bson_corpus.t` (new) | Runner for the official BSON corpus, downloaded by `make spec-data` and not committed | 1, 4 |
| `lib/resty/mongol/init.lua` | Connection object. Local module table, no `module()` | 0, 1, 3 |
| `lib/resty/mongol/misc.lua` | `attachpairs_start` and a local `opairs` that honors `__pairs`. No `_G` write | 0 |
| `lib/resty/mongol/ll.lua` | Byte helpers, plus int64 encode and decode | 1 |
| `lib/resty/mongol/bson.lua` | BSON encode and decode, ordered docs, integer wrappers, types | 1, 4 |
| `lib/resty/mongol/wire.lua` (new) | `OP_MSG` encode, decode, send, receive, command monitoring hook | 1, 5 |
| `lib/resty/mongol/dbmt.lua` | `db:cmd()` over `wire`, database methods | 1, 2, 3 |
| `lib/resty/mongol/colmt.lua` | Collection methods over commands | 2, 5 |
| `lib/resty/mongol/cursor.lua` | Cursor over `find` and `getMore` | 2 |
| `lib/resty/mongol/scram.lua` (new) | SCRAM-SHA-1 and SCRAM-SHA-256 | 3 |
| `lib/resty/mongol/uri.lua` (new) | `mongodb://` parsing | 5 |
| `lib/resty/mongol/session.lua` (new) | Sessions and transactions | 5 |
| `lib/resty/mongol/gridfs.lua`, `gridfs_file.lua` | GridFS on the new collection methods | 5 |
| `CHANGELOG.md`, `Readme.md`, `lua-resty-mongol-*.rockspec`, `dist.ini` | Release files | 6 |

---

## Phase 0: Baseline and CI

### Task 1: CI, test setup, no globals

**Files:**
- Create: `LICENSE`, `.github/workflows/test.yml`, `t/lib/Mongol.pm`, `.luacheckrc`
- Modify: `Makefile:15-16`, `lib/resty/mongol/init.lua:1` and `:136-140`, `lib/resty/mongol/misc.lua:11-35`, all `t/*.t` headers
- Test: `t/globals.t` (new)

**Interfaces:**
- Produces: `t/lib/Mongol.pm` exports `$HttpConfig`. It sets `lua_package_path "$pwd/lib/?.lua;$pwd/lib/?/init.lua;;"`. It also sets these defaults: `TEST_NGINX_MONGO_HOST=127.0.0.1`, `TEST_NGINX_MONGO_PORT=27017`, `TEST_NGINX_MONGO_USER=admin`, `TEST_NGINX_MONGO_PASS=admin`.
- Produces: `misc.opairs(t)`, a local iterator that honors `__pairs`. `bson.lua` uses it in place of `pairs`.
- Produces: `require "resty.mongol"` returns a table `M`, with `M.new(self)` and `M:new()`.

- [ ] **Step 1: Write the failing test.** `t/globals.t`, `TEST 1: no global writes`. The test runs with `lua_code_cache on`, plus an `init_by_lua_block`. The block first stores `package.loaded.saved_pairs = pairs`. Then it does `setmetatable(_G, {__newindex = function(_, k) error("global " .. k) end})`. The `__newindex` trap catches only new keys, so the test must also compare `pairs`. The content block requires `resty.mongol` and calls `mongol:new()`. If `pairs == package.loaded.saved_pairs`, it says `ok`. If not, it says `changed`. Expected `response_body`: `ok`. Expected: `--- no_error_log` of `[error]`.
- [ ] **Step 2: Run** `prove t/globals.t`. Expected: FAIL. `module()` and `_G.pairs` write globals.
- [ ] **Step 3: Implement.** In `init.lua`, replace `module(...)` and the `getmetatable(resty.mongol).__newindex` block with `local _M = {}` and `return _M`. Keep `_M.new`. In `misc.lua`, delete the `_G.pairs` override and add `opairs`. In `bson.lua`, use `opairs` in `to_bson`.
- [ ] **Step 4: Run** `prove t/globals.t`. Expected: PASS.
- [ ] **Step 5: Add CI.** In `test.yml`, use `ubuntu-latest` with a matrix of `mongo: ["6.0", "7.0", "8.0", "9.0"]` and a `services.mongo` container on port 27017, without auth. Install OpenResty 1.31.1.1 from the OpenResty apt repo. Install Test::Nginx with `cpanm --notest Test::Nginx`. Then run `make test`. Set `permissions: contents: read`, and pin every third-party action by commit SHA. In `Makefile`, add three targets. `test` runs `prove -I t/lib t/*.t`, which is not recursive. `test-auth` runs `prove -I t/lib t/auth`. `test-replset` runs `prove -I t/lib t/replset`. Each target puts `$(OPENRESTY_PREFIX)/nginx/sbin` first in `PATH`. Make `install` honor `DESTDIR`. The no-auth jobs run only `make test`. Move every `t/*.t` header to `use lib 't/lib'; use Mongol;`. Replace the literal ports and credentials in the tests with `$TEST_NGINX_MONGO_*`.
- [ ] **Step 6: Add lint.** Write `.luacheckrc` with `std = "ngx_lua"`, `redefined = false` and `unused_args = false`, as `lua-resty-redis` does. Add a CI job `lint` that runs `luacheck -q lib` and `lj-releng` from `openresty/openresty-devel-utils`. Fix every finding in `lib/`. Add `_M._VERSION = "0.9.0"` to `init.lua`.
- [ ] **Step 7: Push the branch and read the CI result.** Expected: all four jobs start their server, `lint` and `t/globals.t` pass, and the old tests fail. Record the failing test names in the PR description. This is the Phase 0 exit gate.
- [ ] **Step 8: Commit** `chore(ci): add MongoDB 6-9 matrix, lint, license, remove globals`.

### Task 1b: Load anywhere, spec ObjectId

Issues: #47, #58, #63, #69, #33. PRs: #49, #20 (ideas only, superseded).

**Files:**
- Modify: `lib/resty/mongol/object_id.lua`, `lib/resty/mongol/init.lua` (`new`, `connect`)
- Test: `t/objid.t`, `t/globals.t`

**Interfaces:**
- Produces: `mongol:new()` makes no cosocket. `conn:connect()` creates `ngx.socket.tcp()` on the first call. Before `connect`, `set_timeout` stores the value and applies it at socket creation.
- Produces: ObjectId bytes follow the current BSON spec: 4-byte big-endian seconds, then 5 random bytes, then a 3-byte big-endian counter. The 5 random bytes come from `resty.random.bytes(5)` on the first id in each worker, keyed by `ngx.worker.pid()`, so that forked workers never share them. The counter starts at a random value. The module calls no `ngx.var`, no `io.popen` and no `uname` at load.
- Produces: `object_id.new_from_hex(hex24) -> oid | nil, err` (issue #33). `oid:tostring()` keeps its output.

- [ ] **Step 1: Write failing tests:**
  - `t/globals.t`, `TEST: require and new in init_by_lua`. `init_by_lua_block` runs `require("resty.mongol"):new()`. Expected: no `[error]` (issue #69).
  - `t/objid.t`, `TEST: id in timer`. `ngx.timer.at(0, ...)` creates an ObjectId and writes its hex to a shared dict. The content handler reads 24 hex characters (issues #47 and #63).
  - `t/objid.t`, `TEST: hex round trip`. `new_from_hex(id:tostring()):tostring() == id:tostring()`.
  - `t/objid.t`, `TEST: unique across workers`. Use `master_on()` and `workers(2)`. An `init_worker_by_lua_block` makes one ObjectId and stores its hex in a shared dict under the key `ngx.worker.id()`. The content handler reads both keys. The ids from the two workers differ in bytes 5 to 9.
- [ ] **Step 2: Run** `prove t/objid.t t/globals.t`. Expected: FAIL.
- [ ] **Step 3: Implement** the interfaces above.
- [ ] **Step 4: Run** the same command. Expected: the new blocks PASS. The existing `t/objid.t` TEST 1 needs a server and the old opcodes, so it fails until Task 5.
- [ ] **Step 5: Commit** `fix(objectid): spec layout, no ngx.var, loadable in any phase`.

### Task 1c: API coverage baseline

The tests before this task never call 9 documented methods and 3 undocumented ones. This task adds a test for each documented method. A `baseline` CI job runs the tests on `mongo:4.4` with the old protocol code. MongoDB 4.4 is the last server that the old code can talk to. A block that passes there records the real old behavior. Later tasks must keep it on 6.0 to 9.0.

Six methods are broken in the old code, so their blocks describe the target behavior and skip on the baseline. `db:list()` is in the README, but the code has no such method. `db:add_user` calls `self:update`, which does not exist. `col:kill_cursors` puts the collection name into `OP_KILL_CURSORS`, but that message has no name field. The server reads the name bytes as the cursor count. `db:listcollections` reads `system.namespaces`, which WiredTiger does not have. `gridfs_file:read(size, offset)` starts at the right chunk but ignores the offset inside that chunk. `conn:shutdown()` raises a Lua error, because the server closes the socket before it replies.

**Files:**
- Create: `t/api.t`
- Modify: `.github/workflows/test.yml` (new job `baseline`)
- Test: `t/api.t`

**Interfaces:**
- Consumes: `t/lib/Mongol.pm` and `$TEST_NGINX_MONGO_*` from Task 1.
- Produces: every block in `t/api.t` has exactly 3 checks: the status code, `response_body` and one `no_error_log` line. The file header uses `plan tests => repeat_each() * (3 * blocks())`. A block that must not run on the baseline has `--- skip_eval: 3: $ENV{TEST_NGINX_MONGO_BASELINE}` and a comment with the reason. The number 3 is the count of checks that the block skips.
- Produces: the CI job `baseline`. It runs on `mongo:4.4` without auth, with `TEST_NGINX_MONGO_BASELINE=1`, and runs only `prove -I t/lib t/api.t`. Task 3 deletes this job.
- Produces: `t/api.t` runs in `make test`. It fails on 6.0 to 9.0 until Task 5, as the other old tests do.

- [ ] **Step 1: Write the tests** in `t/api.t`. Each block uses the database `mongol_api` and starts with a `drop` of the collection that it uses. Each block prints `select("#", ...)` of the call under test, so that the count of return values is recorded too:
  - `TEST: cmd ping`. `db:cmd({ping = 1})` returns a table with `ok == 1`.
  - `TEST: cmd error`. `db:cmd({nosuchcmd = 1})` returns `nil` and a string as its first two values. Print only these two, because the old code also returns a fourth value, the flags table.
  - `TEST: databases`. After an insert into `mongol_api`, `conn:databases()` returns a list that has an entry with `name == "mongol_api"`.
  - `TEST: dropDatabase`. `db:dropDatabase()` returns `1`. After it, `conn:databases()` has no entry for `mongol_api`.
  - `TEST: query and getmore`. Insert 5 documents with `n = 1..5`. `col:query({}, nil, 0, 2)` returns an 8-byte id that is not all zeros, 2 results, and a flags table. `col:getmore(id, 10, 2)` returns 3 results and an id of 8 zero bytes.
  - `TEST: kill_cursors`. Skip on the baseline. `col:query({}, nil, 0, 2)` on the same 5 documents, then `col:kill_cursors({id})`, returns a truthy value. A later `col:getmore(id, 10)` returns flags with `CursorNotFound == true`.
  - `TEST: getprimary standalone`. `conn:getprimary()` returns a connection whose `ismaster()` is `true`.
  - `TEST: count with filter`. Insert `{x = 1}`, `{x = 1}` and `{x = 2}`. `col:count({x = 1})` returns `2`.
  - `TEST: gridfs read aligned`. Insert a 3-chunk file with `chunkSize = 4` through `gridfs:insert`, as `t/gridfs.t` does. `read(4, 4)` returns bytes 5 to 8. `read()` returns the whole file.
  - `TEST: gridfs read unaligned`. Skip on the baseline. `read(3, 5)` returns bytes 6 to 8.
  - `TEST: add_user`. Skip on the baseline. The block first runs `db:cmd({dropUser = "u_api"})` and ignores its error. `db:add_user("u_api", "p")` returns a truthy value, and `db:cmd({usersInfo = "u_api"}).users[1].user` is `u_api`.
  - `TEST: listcollections`. Skip on the baseline. After an insert into `c_api`, the cursor yields a document with `name == "c_api"`.
  - `TEST: db list`. Skip on the baseline. `db:list()` returns a cursor that yields the same documents as `db:listcollections()`.
  - `TEST: shutdown`. Skip on the baseline. Use `--- tcp_listen: 12345` and an empty `--- tcp_reply:`, so that the fake server reads the request and closes the socket. `conn:connect` to port 12345, then `conn:shutdown()`, raises no Lua error. The block has `--- no_error_log` of `[error]`.
- [ ] **Step 2: Add the `baseline` job** to `test.yml`.
- [ ] **Step 3: Push and read the CI result.** Expected: in the `baseline` job, every block that does not skip passes. If a block fails there, the test is wrong, not the old code. Fix the test until it passes on the baseline.
- [ ] **Step 4: Commit** `test: cover every documented API call, baseline on MongoDB 4.4`.

---

## Phase 1: Wire protocol

### Task 2: Ordered BSON and integer wrappers

**Files:**
- Modify: `lib/resty/mongol/ll.lua`, `lib/resty/mongol/bson.lua`
- Test: `t/bson.t` (new, no server needed)

**Interfaces:**
- Produces: `ll.int64_to_le(v) -> string(8)`, where `v` is a Lua number or `int64_t` cdata. `ll.le_to_int64(s, i) -> number | int64_t cdata`. It returns a Lua number for magnitudes up to 2^53, and cdata above that.
- Produces: `bson.int32(n)`, `bson.int64(n)` and `bson.double(n)`. Each returns a wrapper table with a private metatable. `to_bson` writes type 0x10, 0x12 or 0x01 for these.
- Produces: `bson.ordered({ {k1, v1}, {k2, v2}, ... })`. It returns a document whose keys `to_bson` writes in the given order.
- Produces: `bson.to_bson(t) -> string | nil, err`. It no longer raises. Keys with `\0` return `nil, "invalid key"`.
- Produces: `bson.from_bson(get)` reads type 0x12 with `ll.le_to_int64`.
- Produces: array detection does not depend on `pairs` order (issue #52). Let `n` be the count of keys. If `n` is 0, the table is a document, so `filter = {}` stays a document. If `n` is above 0 and every key is an integer from 1 to `n`, the table is an array. Any other table is a document. A document writes a number key as `tostring(k)`, so `{[0] = "a", "b"}` becomes `{"0": "a", "1": "b"}`. A key of any other type returns `nil, "invalid key"`. Delete the old `_keys` and `_vals` encode branch in `to_bson` and the matching rewrite in the decoder. Today a real document with exactly the fields `_keys` and `_vals` reads back as a different table.
- Produces: `bson.empty_array`, a sentinel that `to_bson` writes as an array with no elements (type 0x04). Commands such as `createUser` need it for `roles`. Issue #66 uses it too.
- Produces: `bson.array_mt`. The decoder sets this metatable on every array that it reads, so that an empty array stays an array. The encoder writes a table with this metatable as an array. This is also true for an empty table. The decoder does not return the shared `bson.empty_array`, because a caller can change a decoded table.
- Produces: `ll.num_to_le_uint` and `ll.num_to_le_int` return `nil, "number out of range"` and do not `assert` (issue #16, PR #20).

- [ ] **Step 1: Write failing tests** in `t/bson.t`:
  - `TEST: ordered keys`. `to_bson(bson.ordered{{"find","c"},{"filter",{}},{"limit",bson.int32(1)}})` has `find` as its first element name, and the element type of `limit` is `0x10`.
  - `TEST: int64 above 2^53`. Decoding the 8 bytes of `9007199254740993` gives `tostring(v) == "9007199254740993LL"`.
  - `TEST: empty table vs empty array`. `to_bson({f = {}})` writes `f` as type 0x03. `to_bson({f = bson.empty_array})` writes `f` as type 0x04 with no elements.
  - `TEST: number keys`. `to_bson({t = {[0] = "a", "b"}})` writes `t` as a document with the keys `"0"` and `"1"`. A mixed table `{1, 2, x = 3}` writes a document with the keys `"1"`, `"2"` and `"x"`. A document with the fields `_keys` and `_vals` decodes with those two fields.
  - `TEST: nul in values`. The string `"a\0b"` round trips with a length of 3. The key `"a\0b"` returns `nil` and `invalid key`.
- [ ] **Step 2: Run** `prove t/bson.t`. Expected: FAIL.
- [ ] **Step 3: Implement** the interfaces above. For int64 bytes, use `ffi.new("int64_t[1]")` and `ffi.string(p, 8)`, because the target CPUs are little-endian.
- [ ] **Step 4: Run** `prove t/bson.t`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(bson): ordered documents and int32/int64 wrappers`.

### Task 2b: Number encoding and array indexes (breaking)

Owner decisions: Option B for numbers, 1-based arrays, both in the first release. Issues: #1, #14, #29, #59. PRs: #40, #57.

**Files:**
- Modify: `lib/resty/mongol/bson.lua` (`pack`), `lib/resty/mongol/init.lua` (exports), `lib/resty/mongol/gridfs_file.lua` (`read`, `write`, `update_md5`)
- Test: `t/bson.t`

**Interfaces:**
- Consumes: `bson.int32`, `bson.int64`, `bson.double`, `ll.int64_to_le`.
- Produces: `pack` for a plain Lua number `v`:
  - A finite value with `v == math.floor(v)` and `-2^31 <= v <= 2^31 - 1` is int32.
  - A finite whole number with `-2^63 <= v < 2^63` is int64.
  - Any other value, and `-0.0`, is a double.
  - `int64_t` cdata is int64.
- Produces: `mongol.int32`, `mongol.int64` and `mongol.double` on the module table returned by `require "resty.mongol"`.
- Produces: array indexes. Today a Lua array `{a, b}` is stored as `[null, a, b]`, and a stored array `[a, b]` reads back as `{[0] = a, b}`. The fix writes Lua index `i` as BSON key `i - 1`, and reads BSON key `k` as Lua index `k + 1`. Old data with a leading `null` reads back shifted by one. `CHANGELOG.md` must say so.
- Produces: int32 reads are signed (issue #59).
- Produces: `bson.null`, a unique sentinel table (owner decision). `to_bson` writes it as type 0x0A. A read of type 0x0A returns `bson.null` in documents and in arrays, so keys and array positions stay. Today a null reads as `nil`, so code such as `if doc.x then` changes meaning. This change ships in `1.0.0` (PR #39 idea, without its global `null`).
- Produces: UTC dates read as the same wrapper that `bson.get_utc_date(ms)` makes, with the field `v`. The value `v` is signed, so dates before 1970 are correct (issue #53). Above 2^53, it is `int64_t` cdata. Today a date reads as a plain unsigned number, so this change ships in `1.0.0`.
- Produces: binary values keep their subtype. `bson.get_bin_data(data, subtype)` takes an optional subtype, a number from 0 to 255 with a default of 0. A read of type 0x05 returns the same wrapper, with the fields `v` (the bytes) and `st` (the subtype byte), for every subtype. Today a read returns a plain string and drops the subtype, so this change ships in `1.0.0`. Subtype 0x02 has an extra inner length, and the encoder and decoder must handle it.
- Produces: GridFS keeps working with the binary wrapper. `gridfs_file:read`, `write` and `update_md5` read chunk bytes from the `v` field of the chunk wrapper, for example `od.data.v` in `write`. `read` still returns a Lua string. Without this change, `read()` raises `bad argument #1 to 'sub'` in `1.0.0`.
- Produces: `bson.timestamp(t, i)` writes type 0x11. A read of type 0x11 returns the same wrapper, with fields `t` and `i`. Today it reads as one int64 number, so this change ships in `1.0.0`.

- [ ] **Step 1: Write failing tests.** `TEST: number edges` encodes each value and checks the element type byte:

  | Input | Type byte |
  |---|---|
  | `2^31 - 1` | `0x10` |
  | `2^31` | `0x12` |
  | `-2^31 - 1` | `0x12` |
  | `0.5` | `0x01` |
  | `-0.0` | `0x01` |
  | `1e300` | `0x01` |
  | `0/0` | `0x01` |
  | `bson.double(1)` | `0x01` |
  | `9007199254740993LL` (cdata) | `0x12` |

  Also add `TEST: array encode`. `to_bson({v = {"a", "b"}})` has element names `"0"` and `"1"` inside `v`, and no null element. Add `TEST: array decode`. A hand-built BSON array `["a", "b"]` decodes to `t[1] == "a"`, `t[2] == "b"` and `t[0] == nil`. Add `TEST: empty array round trip`. The document `{a: []}` decodes to a table whose `a` has `bson.array_mt`. `to_bson` of that table writes `a` as type 0x04. Add `TEST: negative int32 decode`. The int32 bytes `ff ff ff ff` decode to `-1`. Add `TEST: null decode`. A document `{x: null}` decodes to `t.x == bson.null`. Add `TEST: array with null`. The array `["a", null, "b"]` decodes to `{"a", bson.null, "b"}`, and encodes back as an array with 3 elements and a null in the middle. Add `TEST: date round trip`. The date `-1000` ms decodes to a wrapper with `v == -1000`, and encodes back as type 0x09 with the same 8 bytes. Add `TEST: binary subtype`. `bson.get_bin_data("abc", 4)` encodes as type 0x05 with subtype 0x04, and decodes to a wrapper with `v == "abc"` and `st == "\4"`. Add `TEST: timestamp round trip`. `bson.timestamp(100, 7)` encodes as type 0x11 and decodes to `t == 100` and `i == 7`.
- [ ] **Step 1b: Add the BSON corpus runner.** The official BSON test data is in `mongodb/specifications`, folder `source/bson-corpus/tests`. Its license is CC BY-NC-SA 3.0. Do not commit these files to this repo. Add a Makefile target `spec-data`. It downloads the folder from commit `9ea18a92308ed437e16dd95e6ff9c496daa61ecd` through `https://codeload.github.com/mongodb/specifications/tar.gz/<sha>` into `t/spec/bson-corpus/`. Add `t/spec/` to `.gitignore`. Make `test` depend on `spec-data`. Write `t/bson_corpus.t`. It needs no server. It reads each JSON file with `cjson` and runs three checks:
  - `valid` entries: `from_bson` of `canonical_bson` succeeds. Then `to_bson` of the result gives the same bytes. Skip the encode check in three cases, because a Lua value cannot carry the BSON type or the key order. The cases are a double with a whole value, an int64 inside the int32 range, and a document with more than one key.
  - `decodeErrors` entries: `from_bson` raises an error or returns `nil`. It must never return a document.
  - The runner reads an allowlist of 13 files. The files are `array`, `binary`, `boolean`, `datetime`, `document` and `double`. The others are `int32`, `int64`, `null`, `oid`, `string`, `timestamp` and `top`. An entry that fails because of work in a later task goes in a `known_failures` table, with the task number. Task 10 adds the files for the Task 10 types and empties `known_failures`. The files for deprecated types, such as `code`, `symbol`, `dbpointer` and `multi-type`, stay out of the allowlist.
- [ ] **Step 2: Run** `prove t/bson.t t/bson_corpus.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `prove t/bson.t t/bson_corpus.t`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(bson)!: int32/int64 numbers and 1-based arrays`. The body explains both breaking changes.

### Task 3: OP_MSG transport and db:cmd

**Files:**
- Create: `lib/resty/mongol/wire.lua`
- Modify: `lib/resty/mongol/dbmt.lua:16-31`, `lib/resty/mongol/init.lua` (`ismaster`, `getprimary`, `databases`, `shutdown`)
- Test: `t/wire.t` (new)

**Interfaces:**
- Consumes: `bson.ordered`, `bson.to_bson`, `bson.from_bson`.
- Produces: `wire.command(conn, dbname, cmd, sequences) -> reply_doc | nil, err, reply_doc`.
  - `cmd` is an ordered document or a plain table. `wire.command` does not change `cmd`. It encodes `cmd` first, so that the command name stays the first key under the Phase 1 key-order rule. Then it adds `$db = dbname` to the encoded bytes, before the final NUL byte. `$readPreference` (Task 12) and the session fields from `session:fields()` (Task 14) are added the same way. Do not set these keys in the Lua table, because `pairs` order can then put one of them first.
  - `sequences` is optional. It is a list of `{identifier, docs}` and becomes kind-1 sections.
  - If `reply.ok ~= 1`, the result is `nil, reply.errmsg, reply`.
  - On a socket or framing error, it calls `conn.sock:close()`, sets `conn.broken = true` and returns `nil, err`.
  - It accepts `flagBits` with bit 0 (`checksumPresent`) set, and drops the last 4 bytes.
  - It rejects reply opcodes other than 2013 with `nil, "unexpected opcode " .. op`.
  - It checks `flagBits` as the `OP_MSG` specification defines. Bits 0 to 15 are required bits. Bit 0 (`checksumPresent`) is allowed. Any other required bit, including bit 1 (`moreToCome`, which this driver never asks for), is an error. Bits 16 to 31 are optional, and the driver ignores them. It rejects a section kind other than 0 or 1, a reply without exactly one kind-0 section, and a section that ends past the message. Each case returns `nil, err`, closes the socket and sets `conn.broken = true`. Source: the MongoDB `OP_MSG` specification.
  - `conn:connect()` on a broken connection makes a new socket and clears `broken`.
  - The driver does not check the reply's `responseTo`. A socket carries one request at a time, and any error closes it, so a reply always belongs to the last request. This rule lets the fake-server tests use a fixed `tcp_reply`.
- Produces: `wire.limits`, a module table with `max_bson_size = 16777216`, `max_message_size = 48000000` and `max_write_batch_size = 100000`. These values are the same on MongoDB 6.0 to 9.0, so the driver does not read them from `hello`. Tests can lower them. If an encoded command is larger than `max_message_size`, `wire.command` returns `nil, "message too large"` and sends nothing.
- Produces: `db:cmd(q)` calls `wire.command(self.conn, self.db, q)`. It keeps the return values `doc` and `nil, errmsg, doc`.
- Produces: if `self.broken` is set, `conn:set_keepalive(...)` returns `nil, "closed"`.
- Produces: `conn:ismaster()` sends `{hello = 1}` and returns `r.isWritablePrimary, r.hosts`.

- [ ] **Step 1: Write failing tests** in `t/wire.t`:
  - `TEST: hello`. `conn:ismaster()` against `$TEST_NGINX_MONGO_HOST` returns `true`. The response body is `true`.
  - `TEST: cmd error`. `db:cmd({nosuchcmd = 1})` returns `nil` and a message that contains `no such command`.
  - `TEST: truncated reply`. Use `--- tcp_listen: 12345` and `--- tcp_reply` with 10 bytes. `db:cmd({ping = 1})` returns `nil, err`, and `conn:set_keepalive()` returns `nil, "closed"`.
  - `TEST: $db does not reorder`. `db:cmd({hello = 1})` and `db:cmd({isMaster = 1})` both return a table with `ok == 1`, and the caller's table has no `$db` key after the call.
  - `TEST: bad replies`. Three blocks, each with `--- tcp_listen: 12345` and a hand-built `OP_MSG` reply. The first has `flagBits` bit 2 set. The second has a section of kind 2. The third has only a kind-1 section. Each `db:cmd({ping = 1})` returns `nil, err`, and `conn:set_keepalive()` returns `nil, "closed"`.
  - `TEST: optional flag bit`. A hand-built reply with `flagBits` bit 20 set and `{ok = 1}` in the body. `db:cmd({ping = 1})` returns a table with `ok == 1`.
  - `TEST: checksum flag`. Use `--- tcp_reply` with a hand-built `OP_MSG` reply that has bit 0 set and `{ok = 1}` in the body. `db:cmd` returns a table with `ok == 1`.
- [ ] **Step 2: Run** `prove t/wire.t`. Expected: FAIL.
- [ ] **Step 3: Implement** `wire.lua`. Header: `messageLength`, `requestID`, `responseTo`, `opCode = 2013`. Body: `flagBits`, section kind 0 with the command, then one kind-1 section for each sequence (`int32 size`, `cstring identifier`, docs). Keep the request id counter as a module upvalue.
- [ ] **Step 3b: Add the send-only path.** `wire.send_only(conn, dbname, cmd, sequences) -> true | nil, err` sets `flagBits` bit 1 (`moreToCome`) and reads no reply. Task 4 uses it for `w = 0` writes. Add `TEST: unsafe write then command`. It calls `wire.send_only` with an `insert` command and `writeConcern = {w = 0}`, then `db:cmd({ping = 1})` on the same socket, and gets `ok == 1`. This test does not use `col:insert`, which Task 4 ports. Source: the MongoDB `OP_MSG` specification.
- [ ] **Step 3c: Delete the `baseline` CI job** from Task 1c. The old protocol code is gone, and MongoDB 4.4 is not a supported server.
- [ ] **Step 4: Run** `prove t/wire.t t/bson.t`. Expected: PASS on all four servers in CI.
- [ ] **Step 5: Commit** `feat(wire): send all commands as OP_MSG`.

---

## Phase 2: CRUD on commands

### Task 4: Writes (insert, update, delete)

**Files:**
- Modify: `lib/resty/mongol/colmt.lua:30-208` (delete the opcode table, `compose_msg`, `docmd`, `read_msg_header`, `handle_reply`)
- Test: `t/sanity.t` (existing tests, ported to `$TEST_NGINX_MONGO_*`), plus new blocks. Most blocks call `db:auth("admin", "admin")` only as setup. Keep those blocks in their files, and delete the `db:auth()` lines and the `auth failed` lines from the expected output. This covers `t/sanity.t` (15 blocks), `t/cursor.t` (4 blocks), `t/gridfs.t` (4 blocks), `t/gridfs_write.t` (15 blocks) and `t/objid.t` (1 block). Move only the blocks whose purpose is login, `t/cluster.t` TEST 2 (`db auth failed`) and TEST 8 (`db auth`), to `t/auth/legacy.t`. That file runs only in the Phase 3 auth job. In the moved blocks, log in against the `admin` database, because the CI root user lives there. Rewrite `t/sanity.t` TEST 16 for the Task 2b rules. `tab1 = {[0] = "a0", "a1", "a2"}` and the sparse `tab2` are not arrays, so they are stored as documents. The new expected values are `r.tab[1].a == "aa"`, `r.tab1["0"] == "a0"` and `r.tab2["2"] == "a20"`. Rewrite TEST 18 the same way. `$push` works only on arrays, so its fixtures for `tab1` and `tab2` become the arrays `{"a10", "a11", "a12"}` and `{"a22", "a23", "a24"}`. The update returns `1`. The new expected values are `r.tab[2].b == "bb"`, `r.tab[3] == "a3"`, `r.tab1[4] == "a13"` and `r.tab2[4] == "a25"`. Rewrite TEST 11. It inserts 10 documents and reads them with `find(..., 4)`. The value 4 is now the batch size and not a limit, so the test expects all 10 documents. Rewrite TEST 12 the same way. It reads 10 documents twice with `find(..., 3)`, once with `{n = 0}` and once with `{n = 1}`. Each loop now prints all 10 documents. The first loop prints `nil` and `puppy` for each document, and the second prints `n` from 1 to 10 and `nil`. Keep TEST 22 unchanged. It now passes with the standard `pairs`.

**Interfaces:**
- Consumes: `wire.command`, `bson.ordered`, `bson.int32`.
- Produces: unchanged signatures. `col:insert(docs, continue_on_error, safe)`, `col:update(selector, update, upsert, multiupdate, safe)` and `col:delete(selector, single_remove, safe)`.
  - `insert` sends `insert`, with `documents` as a kind-1 sequence and `ordered = not flag(continue_on_error)`. If the write is safe and succeeds, it returns `0`.
  - `update` sends `{q, u, upsert = flag(upsert), multi = flag(multiupdate)}` as BSON booleans. If the write is safe, it returns `reply.n`.
  - `delete` sends `{q, limit = flag(single_remove) and 1 or 0}`. If the write is safe, it returns `reply.n`.
  - Unsafe writes use `wire.send_only` from Task 3.
  - `insert` splits `docs` into batches. A batch has at most `wire.limits.max_write_batch_size` documents. The driver computes the size of the message without documents: the 16-byte header, the 4-byte `flagBits`, the kind-0 section with the encoded command, and the kind-1 section header. The command and the header plus the documents of a batch must fit in `wire.limits.max_message_size`. If one document is larger than `wire.limits.max_bson_size`, or does not fit in a message alone, the call returns `nil, "document too large"` and sends nothing.
  - If the insert is ordered, the driver stops after the first batch with a write error. If it is unordered, the driver sends every batch and returns the first error message. In both cases, a safe insert without errors returns `0`.
  - If the write is unsafe, each call sends `writeConcern = {w = 0}` and returns `-1`.
  - If the reply has `writeErrors` or `writeConcernError`, the call returns `nil` and the first `errmsg`.
- Produces: `local function flag(v) -> boolean`. It returns `false` for `nil`, `false` and `0`, and `true` for any other value. It is used for `safe`, `continue_on_error`, `upsert`, `multiupdate` and `single_remove`. In Lua, `0` is truthy, so code must not test these arguments directly.
- Add `TEST: insert split`. Set `wire.limits.max_message_size = 20000`. A safe insert of 50 documents of 1,000 bytes each returns `0`, and `count({})` gives `50`. Add `TEST: document too large`. Set `wire.limits.max_bson_size = 100`. An insert of a 200-byte document returns `nil` and `document too large`, and `count({})` gives `0`. Add `TEST: ordered stop across batches`. Use the same lowered limit and 50 documents, with a duplicate `_id` at position 2. The ordered insert gives `count({}) == 1`. The same insert with `continue_on_error = 1` gives `count({}) == 49`. Each test restores the limits at the end.
- Add `TEST: delete with flag 0`. Insert 3 documents, then `delete({}, 0, true)` gives `3`. Add `TEST: update with flags 0`. `update({x = 9}, {["$set"] = {y = 1}}, 0, 0, true)` on an empty collection gives `0`, and a later `count({})` gives `0`.

- [ ] **Step 1: Write failing tests** in `t/sanity.t`:
  - `TEST: insert safe returns 0`. `col:insert({{name="dog"}}, nil, true)` gives `0`.
  - `TEST: insert unsafe returns -1`. `col:insert({{name="dog"}})` gives `-1`.
  - `TEST: duplicate key`. Two safe inserts with the same `_id` give `nil` and a message that contains `E11000`.
  - `TEST: continue_on_error`. A safe batch of three documents, with a duplicate in the middle and `continue_on_error = 1`, gives `nil, err`. A later `count({})` is `2`.
  - `TEST: update multi`. Three documents, then `update({}, {["$set"]={x=1}}, 0, 1, true)`, give `3`.
  - `TEST: delete single`. Three documents, then `delete({}, 1, true)`, give `1`.
- [ ] **Step 2: Run** `prove t/sanity.t`. Expected: the new blocks FAIL.
- [ ] **Step 3: Implement** the interfaces above.
- [ ] **Step 4: Run** `prove t/sanity.t`. Expected: the new blocks PASS.
- [ ] **Step 5: Commit** `feat(col): writes over insert/update/delete commands`.

### Task 5: Reads, count, drop, and database methods

**Files:**
- Modify: `lib/resty/mongol/colmt.lua` (`query`, `getmore`, `kill_cursors`, `count`, `find_one`, `find_and_modify`), `lib/resty/mongol/dbmt.lua` (`listcollections`, `add_user`, `dropDatabase`)
- Test: `t/sanity.t`, `t/cursor.t`

**Interfaces:**
- Produces: `col:query(query, returnfields, numberToSkip, numberToReturn, options) -> cursor_id(string 8), results(table), flags(table) | nil, err`.
  - It sends `find` with `filter`, `projection` and `skip` (int32). `numberToReturn` maps as in the legacy `OP_QUERY`:
    - `nil`: `singleBatch = true` and `limit = 1`, because the old code sends `numberToReturn or -1`.
    - `0`: no `batchSize` and no `limit`.
    - `1` or a negative `n`: `singleBatch = true` and `limit = abs(n)`.
    - A positive `n` above 1: `batchSize = n`, and no `limit`.
  - `options.limit` (new) is the total limit. The cursor sets it from `cursor:limit(n)`. `num_each_query` from `col:find` is only the batch size.
  - `options.sort` (new) becomes `sort`.
  - `cursor_id` is `ll.int64_to_le(reply.cursor.id)`. For an exhausted cursor, it is `"\0\0\0\0\0\0\0\0"`.
  - `flags` has `CursorNotFound = (code == 43)`, `QueryFailure = (any other error)` and `startingFrom`, `numberReturned`.
  - The return values depend on the kind of result. These rules keep the old three values, because old callers read `flags`:
    - Success: `cursor_id, results, flags`.
    - Server error, for example `ok = 0`: `"\0\0\0\0\0\0\0\0", {}, flags, errmsg`. `flags.CursorNotFound` or `flags.QueryFailure` is `true`.
    - Socket or protocol error: `nil, err`.
- Produces: `col:getmore(cursorID, numberToReturn, offset_i)` with the same return values. It sends `getMore = int64` and `collection`. If `numberToReturn` is above 0, it also sends `batchSize = numberToReturn`. If it is `nil`, 0 or less, the command has no `batchSize`. MongoDB rejects a `getMore` with a `batchSize` of 0 or less.
- Produces: `col:kill_cursors(ids)` sends `killCursors` and returns `true | nil, err`.
- Produces: `col:count(query)` sends ordered `{count, query}` and returns `reply.n`.
- Produces: if the reply has `value = bson.null`, `col:find_and_modify(options)` returns `nil`, as the old code did for a miss. A document inside the reply keeps `bson.null` in its fields.
- `db:listcollections()` and `db:list()` move to Task 6, because they need a cursor built from a command reply. `db:add_user(u, p)` sends `createUser` with `roles = bson.empty_array`.

- [ ] **Step 1: Write failing tests:**
  - `TEST: find_one`. Insert `{name="dog"}`. `find_one({name="dog"}).name` is `dog`.
  - `TEST: find_one miss`. The result is `nil`.
  - `TEST: count`. Insert 5 documents, then `count({})` gives `5`. This covers issue #61.
  - `TEST: negative int32` (issue #59). A safe insert of `{v = -1}` and a `find_one` give `v == -1`.
  - `TEST: array round trip`. A safe insert of `{v = {"a", "b"}}`, then a `count` with `{v = {["$size"] = 2}}` gives `1`, and `find_one({}).v[1]` is `a`.
  - `TEST: add_user roles`. After a `dropUser` of `u2` whose error is ignored, `db:add_user("u2", "p2")` succeeds, which needs `roles` to be an empty array.
  - `TEST: $or array` (issue #14). Insert `{x = 1}` and `{y = 2}`. A `count` with `{["$or"] = {{x = 1}, {y = 2}}}` gives `2`.
  - `TEST: query cursor not found`. `col:getmore("\1\0\0\0\0\0\0\0")` returns 4 values. The third is a flags table with `CursorNotFound == true`, and the fourth is a string.
  - `TEST: query server error`. `col:query({["$bad"] = 1})` returns 4 values. The flags table has `QueryFailure == true`, and the fourth value is a string.
  - `TEST: find_and_modify`. Upsert `{x=1}` with `new=true`, and `.x` is `1`.
  - `TEST: find_and_modify miss`. On an empty collection, an update without `upsert` returns `nil`, a `remove = true` returns `nil`, and an upsert without `new = true` returns `nil`.
- [ ] **Step 2: Run** `prove t/sanity.t`. Expected: FAIL. The new blocks of this task are in `t/sanity.t`. The full `t/cursor.t` gate is in Task 6.
- [ ] **Step 3: Implement** the interfaces above.
- [ ] **Step 4: Run** the same command. Expected: PASS, except `t/sanity.t` TEST 11 and TEST 12. These two tests read across batches, which needs the Task 6 cursor. Task 6 Step 4 runs them.
- [ ] **Step 5: Commit** `feat(col): reads over find/getMore commands`.

### Task 6: Cursor

**Files:**
- Modify: `lib/resty/mongol/cursor.lua`
- Test: `t/cursor.t`

**Interfaces:**
- Consumes: `col:query`, `col:getmore`, `col:kill_cursors` from Task 5.
- Produces: `cursor:next() -> i, doc | nil | nil, err`. `cursor:limit(n)`, `cursor:skip(n)` (new), `cursor:sort(field, size)`, `cursor:close() -> true | nil, err` (new) and `cursor:pairs()`.
  - Before the first fetch, `sort` stores the sort in the cursor, fetches with server-side sort, and returns the first batch, as today. The fetch uses the `skip` and `limit` values that the caller set before.
  - `skip(n)` and `limit(n)` must come before the first fetch. After the first fetch, they return `nil, "cursor already started"`.
  - After the first fetch, `sort` keeps today's client-side behavior.
  - Remove `cursor_mt.__gc`.
- Produces: `cursor.from_reply(col, reply_cursor, num_each, session) -> cursor`. It takes `reply_cursor.firstBatch`, `reply_cursor.id` and `reply_cursor.ns`. Every `getMore` and `killCursors` uses the collection part of `ns`. For `listCollections`, this is `$cmd.listCollections`. Task 11 `aggregate` uses this constructor too.
- Produces: `db:listcollections(num_each)` sends `listCollections` and returns `cursor.from_reply(...)`. The optional `num_each` goes out as `cursor = {batchSize = num_each}`, and `from_reply` uses it for each `getMore`. Without it, the command sends `cursor = {}`. `db:list(num_each)` is an alias for it, because the README documents that name.
- Produces: any `getMore` error makes `next()` return `nil, err`. This includes code 43 (`CursorNotFound`) and code 175 (`QueryPlanKilled`). The cursor does not run the query again. Today `next()` runs the query again after `CursorNotFound`, which can return a document twice.

- [ ] **Step 1: Write failing tests** in `t/cursor.t`:
  - `TEST: limit across batches`. Insert 25 documents, then `find({}, nil, 10)` with `limit(23)` yields exactly 23 documents, then `nil`.
  - `TEST: no batch size`. Insert 150 documents. `find({}, nil, 0)` yields exactly 150 documents. The first batch has 101 documents, so this test sends a `getMore` without `batchSize`.
  - `TEST: all documents` (issue #74). Insert 2,500 documents. `find({}, nil, 100)` without a limit yields exactly 2,500 documents.
  - `TEST: skip`. Insert 10 documents with `n = 1..10`, then `skip(3)` and `sort({n=1})` give a first `n` of `4`.
  - `TEST: skip after fetch`. After `next()`, `skip(1)` returns `nil` and `cursor already started`.
  - Rewrite the expected output of the existing `t/cursor.t` TEST 2. It inserts `n = 1..10` and sorts batches of 5. The server sorts all documents, so the descending sort now returns `10, 9, 8, 7, 6`, not `5, 4, 3, 2, 1`. The case with `limit(3)` returns `10, 9, 8`. The ascending cases do not change. `CHANGELOG.md` records this fix.
  - Rewrite the expected output of the existing `t/cursor.t` TEST 1. Its third case uses a batch size of 2 and `limit(5)`, so it now prints `1, 2, 3, 4, 5`, not `1, 2`.
  - `TEST: server sort`. Insert `n = 5, 2, 7, 1, 6, 3, 4`. Then `find({}, nil, 2)` with `skip(1)`, `limit(4)` and `sort({n=-1})` returns the first batch, `6, 5`. A new cursor with the same settings, read with `pairs()` after `sort`, yields `6, 5, 4, 3`. The batch size is 2, so the old client-side sort of one batch cannot pass this test.
  - `TEST: close`. After `close()`, `next()` returns `nil`.
  - `TEST: listcollections`. Create 3 collections, then `db:listcollections(2)` yields all 3 names. The second batch comes from a `getMore` on `$cmd.listCollections`.
  - `TEST: fetch error`. Drop the collection between batches with `num_each = 2`. `next()` returns exactly `nil` and a string.
- [ ] **Step 2: Run** `prove t/cursor.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `make test`. Expected: all blocks in `bson.t`, `bson_corpus.t`, `wire.t`, `sanity.t`, `cursor.t`, `api.t` and `globals.t` PASS on all four servers. `t/gridfs.t`, `t/gridfs_write.t` and the aligned GridFS block in `api.t` must also pass. The `1.0.0` release must not ship a documented call that raises a Lua error. If one fails, fix it in this task before the tag. `cluster.t` and the unaligned GridFS block in `api.t` can still fail. Mark them `--- SKIP` with the reasons "Task 12" and "Task 13". The `shutdown` block in `api.t` must pass. If the server closes the socket after the command, `conn:shutdown()` returns `true`.
- [ ] **Step 5: Commit** `feat(cursor): server cursors, skip, close`.
- [ ] **Step 6: Prepare the first release.** Before the tag, set `_M._VERSION = "1.0.0"`. Create `CHANGELOG.md` with a `1.0.0` section. Add a "Migrating to 1.0" section at the top of `Readme.md`. Both describe these changes:
  - 1-based arrays and their effect on old data.
  - int32 and int64 numbers, and int64 cdata above 2^53.
  - Timestamp wrappers.
  - `bson.null` on read, with an `if doc.x then` example.
  - `cursor:close()` in place of the `__gc` kill.
  - `skip` and `limit` before the first fetch.
  They also list the fixes that a caller can see. `db:list()`, `db:add_user`, `db:listcollections`, `col:kill_cursors` and `conn:shutdown()` work now. A binary value reads as a wrapper with `v` and `st`, not as a plain string. A date reads as a wrapper with `v`, not as a plain number. An array reads as a table with `bson.array_mt`. `cursor:sort()` before the first fetch sorts all documents on the server, not only the first batch. A server error from `col:query` or `col:getmore` adds the error message as a fourth return value. `db:cmd` no longer returns a fourth value, the flags table. `col:find` now yields every matching document across batches (issues #12 and #74). `num_each_query` is only the batch size, and `cursor:limit(n)` caps the results. A table with number keys that is not an array now goes out as a document with string keys, not as `_keys` and `_vals`.
- [ ] **Step 7: Commit** `docs: 1.0.0 changelog and migration guide`. Tag `1.0.0`. It is the major release that contains every breaking change.

---

## Phase 3: Authentication and connection

### Task 7: SCRAM-SHA-1 and SCRAM-SHA-256

**Files:**
- Create: `lib/resty/mongol/scram.lua`
- Modify: `lib/resty/mongol/dbmt.lua:45-187` (`auth`, `auth_scram_sha1`, the helper functions), `.github/workflows/test.yml`
- Test: `t/auth/auth.t` (new)

**Interfaces:**
- Consumes: `wire.command`.
- Produces: `scram.authenticate(conn, dbname, user, password, mechanism) -> true | nil, err`, where `mechanism` is `"SCRAM-SHA-1"` or `"SCRAM-SHA-256"`.
  - SHA-1 uses `md5(user .. ":mongo:" .. password)` as the password, as today.
  - SHA-256 uses the SASLprep of the password. Bytes above 0x7F return `nil, "non-ASCII password not supported"`.
  - PBKDF2 and HMAC use FFI calls to `PKCS5_PBKDF2_HMAC` and `HMAC` in the OpenSSL that nginx links. At 15,000 iterations, pure Lua costs too much worker CPU. If the symbols are missing, the fallback is RFC 2104 HMAC over `resty.sha1` and `resty.sha256` (block size 64) with RFC 8018 PBKDF2.
  - The client nonce is 24 bytes from `resty.random.bytes(24, true)`, in base64.
  - The client checks that the server nonce starts with the client nonce, and checks the server signature `v=`.
  - It caches `salted_password` in a module table. The key is `table.concat({mechanism, user, sha256_hex(prepared_password), salt, iterations}, "\0")`, so a wrong password never matches a cached entry.
  - Add `TEST: wrong password after cached login`. In one worker, log in with the correct password, then log in on a fresh socket with a wrong password. The second login returns `nil` and `Authentication failed`.
- Produces: `db:auth(user, password)` sends `hello` with `saslSupportedMechs = db .. "." .. user`. If the server lists SHA-256, it picks SHA-256. Otherwise, it picks SHA-1. `db:auth_scram_sha1(u, p)` stays as an alias.
- Produces: a CI job `auth`. It runs the four-version matrix with `MONGO_INITDB_ROOT_USERNAME=admin` and `MONGO_INITDB_ROOT_PASSWORD=admin`, and runs only `make test-auth`.

- [ ] **Step 1: Write failing tests** in `t/auth/auth.t`. Each test logs in against the `admin` database:
  - `TEST: sha256 login`. `auth("admin", "admin")` gives `1`. Then `insert(..., true)` gives `0`.
  - `TEST: sha1 login`. Drop the user `u1` and ignore the error. Create a user `u1` with `mechanisms = {"SCRAM-SHA-1"}`. `auth("u1", "p1")` gives `1`.
  - `TEST: wrong password`. The result is `nil` and a message that contains `Authentication failed`.
  - `TEST: rfc7677 vector`. Run `scram.lua`'s client proof over the RFC 7677 example (`user`, `pencil`, nonce `rOprNGfwEbeRWgbNEkqO`) and compare it with the RFC proof. No server is needed.
  - `TEST: pooled login reuse`. Request 1 logs in and calls `set_keepalive(10000, 10)`. Request 2 calls `connect` with the same `pool`, sees `get_reused_times() > 0`, skips login, and its `find_one` succeeds.
- [ ] **Step 2: Run** `make test-auth` against a server with auth on. Expected: FAIL.
- [ ] **Step 3: Implement** the interfaces above.
- [ ] **Step 4: Run** `make test-auth`. Expected: PASS in all four auth jobs.
- [ ] **Step 5: Commit** `feat(auth): SCRAM-SHA-256 with SHA-1 fallback`.

### Task 8: TLS, connect options, getprimary, ngx.var

**Files:**
- Modify: `lib/resty/mongol/init.lua` (`connect`, `getprimary`), every file that uses `ngx.var` (issue #58)
- Test: `t/connect.t` (new)

**Interfaces:**
- Produces: `conn:connect(host, port, opts)`, modeled on `ledgetech/lua-resty-http` `connect(options)`. `opts` is optional.
  - `pool`, `pool_size` and `backlog` go to `sock:connect(host, port, {pool =, pool_size =, backlog =})`.
  - `ssl` (boolean), `ssl_verify` (default `true`), `ssl_server_name` (default `host`) and `ssl_reused_session` go to a separate `sock:sslhandshake(ssl_reused_session, ssl_server_name, ssl_verify)` call.
  - The old two-argument call does not change.
  - `connect` stores `host`, `port` and `opts` after a success. A call with no arguments reuses them. Task 14 needs this for commit recovery.
  - Add `TEST: reconnect keeps options`. `connect(host, port, {pool = "r"})`, then `close()`, then `connect()` with no arguments succeeds.
  - The README says that `ssl_verify` needs `lua_ssl_trusted_certificate`.
- Produces: `conn:getprimary()` uses `hello` and `isWritablePrimary`, with the same return values as today.

- [ ] **Step 1: Write failing tests:**
  - `TEST: pool option`. Two connects with `pool = "a"` show `get_reused_times() == 1` on the second.
  - `TEST: tls to plain server`. `connect(host, port, {ssl = true})` returns `nil, err` and raises no Lua error.
  - In `t/tls/tls.t`, which runs only in the CI job `tls`: `TEST: tls verified`. `connect("127.0.0.1", 27017, {ssl = true, ssl_server_name = "localhost"})` succeeds, and `db:cmd({ping = 1})` returns `ok == 1`. `TEST: tls untrusted`. A second nginx block trusts a different CA, and the same `connect` returns `nil, err`. All three blocks use `127.0.0.1` with `ssl_server_name = "localhost"`. A cosocket cannot resolve `localhost` without a `resolver`, and the certificate name is `localhost`. `TEST: tls reconnect`. After `close()`, `connect()` with no arguments succeeds, and `ping` returns `ok == 1`.
- Produces: the CI job `tls`. It runs only with `mongo:9.0`, to keep CI short. A step makes a test CA and a server certificate for `localhost` with `openssl`. The job starts `mongod` with `--tlsMode requireTLS --tlsCertificateKeyFile server.pem --tlsCAFile ca.pem --tlsAllowConnectionsWithoutCertificates`. MongoDB does not start with TLS and no CA file. The last flag lets the driver connect without a client certificate. `t/tls/tls.t` sets `lua_ssl_trusted_certificate` to the test CA. A new Makefile target `test-tls` runs `prove -I t/lib t/tls`. The certificates are made in CI and never committed.
  - `TEST: pool_size`. `connect(host, port, {pool = "b", pool_size = 1})` succeeds.
- [ ] **Step 2: Run** `prove t/connect.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `make test` and, in the `tls` job, `make test-tls`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(conn): TLS and pool options, hello-based getprimary`. Tag the Phase 3 release.

---

## Phase 4: BSON types

### Task 10: Missing BSON types and JSON

**Files:**
- Modify: `lib/resty/mongol/bson.lua`, `lib/resty/mongol/object_id.lua`
- Test: `t/bson.t`

**Interfaces:**
- Produces: these constructors and their read types:

  | Constructor | BSON type |
  |---|---|
  | `bson.decimal128(str)` | `0x13`, read as the same wrapper, `tostring` gives the decimal string |
  | `bson.regex(pattern, opts)` | `0x0B` |
  | `bson.minkey()` | `0xFF` |
  | `bson.maxkey()` | `0x7F` |

- Reads of types 0x13, 0x0B, 0xFF and 0x7F raise an error today. Returning wrappers for them breaks no caller.
- Produces: `bson.to_json_safe(doc)` returns a copy for `cjson` (issues #53 and #67). `lua-cjson` does not call metamethods, so this function is the only JSON path. In the copy, an ObjectId is a hex string and a date is an ISO 8601 string. `bson.null` becomes `cjson.null`.

- [ ] **Step 1: Write failing tests.** `TEST: type round trip` for each row above, through a real insert and `find_one`. Also add `TEST: empty array stays array` for issue #66, and `TEST: cjson safe` with `cjson.encode(bson.to_json_safe(doc))`, which raises no error and contains the ObjectId hex.
- [ ] **Step 2: Run** `prove t/bson.t`. Expected: FAIL.
- [ ] **Step 3: Implement.** Decimal128 string conversion follows the BSON Decimal128 spec. Add `decimal128-1` to `decimal128-7`, `regex`, `minkey` and `maxkey` to the allowlist in `t/bson_corpus.t`. Empty its `known_failures` table. Run `prove t/bson_corpus.t`. Expected: PASS.
- [ ] **Step 4: Run** `make test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(bson): decimal128, regex, min/max key, JSON helpers`. Tag the Phase 4 release.

---

## Phase 5: New features

### Task 11: aggregate

**Files:** Modify `lib/resty/mongol/colmt.lua`. Test: `t/aggregate.t`.

**Interfaces:**
- Produces: `col:aggregate(pipeline, options) -> cursor | nil, err`. It sends ordered `{aggregate = col, pipeline, cursor = {batchSize = options.batch_size or 100}}` and returns `cursor.from_reply(...)` from Task 6 on the reply (issue #55).

- [ ] **Step 1: Write the failing test.** `TEST: group sum`: insert `{k="a",v=1}`, `{k="a",v=2}` and `{k="b",v=5}`. Then `$group` by `k` with a sum of `v`, and `$sort` on `_id`, yield `a 3` and `b 5`.
- [ ] **Step 2: Run** `prove t/aggregate.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(col): aggregate`.

### Task 11b: Command monitoring hook

Source: the MongoDB Command Logging and Monitoring specification in `mongodb/specifications`. The library sends no metrics itself. Apps connect the hook to Prometheus, OpenTelemetry or logs.

**Files:** Modify `lib/resty/mongol/wire.lua` and `lib/resty/mongol/init.lua`. Test: `t/monitor.t`.

**Interfaces:**
- Consumes: `wire.command` and `wire.send_only` from Task 3.
- Produces: `mongol.set_monitor(m) -> true`, where `m` is `nil` or a table with optional functions `started(ev)`, `succeeded(ev)` and `failed(ev)`. A call with `nil` removes the monitor. The monitor is per worker. A value that is not a table or `nil` raises `error("bad argument #1 ...", 2)`.
- Produces: event fields:
  - All events: `command_name`, `db`, `request_id`, `host`, `port`.
  - `started`: `command`, a copy of the command. Each kind-1 sequence is merged into this copy under its identifier, for example `documents` for `insert`. The command that goes on the wire does not change.
  - `succeeded`: `duration_ms` and `reply`.
  - `failed`: `duration_ms` and `error`, the error string.
- Produces: rules:
  - Without a monitor, `wire.command` does one `if` check and nothing else.
  - The driver calls each hook through `pcall`. A hook error goes to `ngx.log(ngx.ERR, ...)` and does not change the command result.
  - Sensitive commands are `authenticate`, `saslStart`, `saslContinue`, `getnonce`, `createUser`, `updateUser`, `copydbgetnonce`, `copydbsaslstart` and `copydb`. A `hello` or `isMaster` that contains `speculativeAuthenticate` is sensitive too. The check runs inside `wire.command`, so it also covers calls through the public `db:cmd()`. For a sensitive command, `command` and `reply` are empty tables, and `failed.error` is the string `"redacted"`.
  - Event tables are deep copies. The driver builds them before it sends and after it decodes. A hook can change an event and then raise an error. In both cases, the data on the wire and the value that the caller gets do not change. If no monitor is set, the driver makes no copies.
  - At the start of a command, the driver reads the monitor once and keeps it in a local variable. The terminal event goes to that same monitor. Another request or the `started` hook can call `set_monitor` during the command. This does not change where the terminal event goes.
  - Every `started` event has exactly one terminal event. A send failure, a timeout, a closed socket and a reply that cannot be parsed each produce `failed`.
  - `succeeded` means that the command succeeded, not that the write succeeded. A reply `{ok = 1, writeErrors = ...}` produces `succeeded`. For an unsafe write, `succeeded` shows only that the driver sent it.
  - For a `wire.send_only` write, `succeeded` fires after the send, with `reply = {ok = 1}`.
  - `duration_ms` comes from `ngx.now()` after `ngx.update_time()`.

- [ ] **Step 1: Write failing tests** in `t/monitor.t`:
  - `TEST: started and succeeded`. A monitor that appends to a list, then `find_one({})`, records `started` and `succeeded`, both with `command_name == "find"` and the same `request_id`.
  - `TEST: failed`. `db:cmd({nosuchcmd = 1})` records `failed`, and `error` contains `no such command`.
  - `TEST: hook error`. A `started` hook that raises an error does not stop `find_one`, and the error log contains the hook error.
  - `TEST: redaction`. With auth off, the block first drops the user `u3` and ignores the error. Then `db:cmd(bson.ordered{{"createUser", "u3"}, {"pwd", "secret"}, {"roles", bson.empty_array}})` records a `started` event whose `command` is empty, and no event text contains `secret`.
  - `TEST: failed sensitive command`. Drop the user `u3` and ignore the error. Then run the same `createUser` twice. The second call fails because the user exists. Its `failed` event has `error == "redacted"`, and no event text contains `secret` or `u3`.
  - `TEST: speculative hello`. `db:cmd(bson.ordered{{"hello", 1}, {"speculativeAuthenticate", {saslStart = 1}}})` records events with an empty `command` and an empty `reply`.
  - `TEST: insert event`. `col:insert({{a = 1}, {a = 2}}, nil, true)` records a `started` event whose `command.documents` has 2 entries.
  - `TEST: hook mutation`. A `started` hook sets `ev.command.filter.a = 99` and then raises an error. `find_one({a = 1})` still finds the document with `a == 1`. A `succeeded` hook that clears `ev.reply` does not change the value that `find_one` returns.
  - `TEST: monitor removed in flight`. A `started` hook calls `set_monitor(nil)`. The same command still records its `succeeded` event.
  - `TEST: failure on closed socket`. Use `--- tcp_listen: 12345` and an empty `--- tcp_reply:`, so that the fake server closes at once. One `started` and one `failed` event are recorded.
  - `TEST: remove monitor`. After `set_monitor(nil)`, `find_one` records nothing.
- [ ] **Step 2: Run** `prove t/monitor.t`. Expected: FAIL.
- [ ] **Step 3: Implement** the interfaces above. Add a README section with one Prometheus example, a `nginx-lua-prometheus` counter and histogram. Add the warning that hooks run in the request and must not block. The example explains that `succeeded` counts command success, not write success, and shows how to count `reply.writeErrors`.
- [ ] **Step 4: Run** `prove t/monitor.t`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(wire): command monitoring hook`.

### Task 12: Replica set CI, primary selection, URI

**Files:** Create `lib/resty/mongol/uri.lua`. Modify `init.lua` and `.github/workflows/test.yml`. Test: `t/uri.t`, `t/replset/cluster.t`. Move `t/cluster.t` TEST 5 to TEST 7 to `t/replset/cluster.t` and remove their skips. TEST 2 and TEST 8 moved to `t/auth/legacy.t` in Task 4, so `t/cluster.t` is then empty and is deleted.

**Interfaces:**
- Produces: `uri.parse(str) -> {hosts = {{host, port}}, db, user, password, options = {authSource, tls, replicaSet, readPreference}} | nil, err`. It decodes percent-encoding in the user name and the password.
- Produces: `mongol.connect_uri(str) -> conn | nil, err`. The returned `conn` always talks to the primary, and all writes and `db:cmd` calls use it. For `secondary` and `secondaryPreferred`, `conn.read_conn` holds a second connection to the selected secondary. If `conn.read_conn` is set, `col:query`, `col:find`, `col:find_one`, `col:count` and `col:aggregate` use it. A cursor keeps the connection of its first `query` for every `getMore` and `killCursors`. The read connection follows `readPreference` (issues #10 and #22):
  - `primary`: no `read_conn`. Reads use the primary.
  - `primaryPreferred`: no `read_conn` while a primary answers. If no primary answers, `connect_uri` returns `nil, err`, because writes need a primary.
  - `secondary`: use a host whose `hello` reply has `secondary = true`. If none answers, return `nil, err`.
  - `secondaryPreferred`: use a secondary. If none answers, use the primary.
  - Every command on `read_conn` carries `$readPreference = {mode = ...}`. Over `OP_MSG`, a secondary rejects a read with `NotPrimaryNoSecondaryOk` without it. Commands on the primary `conn` never carry it.
  - If the URI has a user, it logs in.
- Produces: a CI job `replset` with a 3-member replica set. It starts three containers with `docker run -d --network host mongo:${{ matrix.mongo }} --replSet rs0 --port <p>`, for the ports 27017, 27018 and 27019. Then it runs `rs.initiate()` through `mongosh` with the members `127.0.0.1:27017` (priority 2), `127.0.0.1:27018` and `127.0.0.1:27019`, and waits until 27017 is primary. The existing `t/cluster.t` uses port 27018 as a secondary. The member names are IP addresses, because `getprimary` and `connect_uri` connect to the names in `hello.hosts`. A cosocket cannot resolve `localhost` without a `resolver`.

- [ ] **Step 1: Write failing tests.** `TEST: uri parse`, with `mongodb://u%40x:p@h1:1,h2/db?authSource=admin&tls=true&replicaSet=rs0`, gives the user `u@x`, two hosts, and `tls == true`. `TEST: connect_uri replset` in `t/replset/uri.t` gives `ismaster() == true`. `TEST: secondary read then write` uses `readPreference=secondaryPreferred`. `conn.read_conn:ismaster()` is `false`, `find_one({})` succeeds, and then a safe `insert` returns `0`. `TEST: getMore on same server` first writes 25 documents through `db:cmd(bson.ordered{{"insert", name}, {"documents", docs}, {"writeConcern", {w = 3}}})`, so that every member has them. Then it reads them with `find({}, nil, 10)` through `read_conn` and gets all 25. The `replset` job runs `make test-replset`.
- [ ] **Step 2: Run** `prove t/uri.t` and, in the `replset` job, `make test-replset`. Expected: FAIL. `t/replset/uri.t` holds `TEST: connect_uri replset`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `prove t/uri.t` and `make test-replset`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(conn): mongodb:// URIs and replica set primary selection`.

### Task 13: GridFS on the new methods

**Files:** Modify `lib/resty/mongol/gridfs.lua` and `gridfs_file.lua`. Test: `t/gridfs.t`, `t/gridfs_write.t`, and the unaligned read block in `t/api.t` (remove its skip).

**Interfaces:**
- Produces: the 8 README GridFS methods with unchanged signatures: `find_one`, `remove`, `get`, `insert`, `new`, `read`, `write` and `update_md5`. `update_md5` stays client-side with `resty.md5`, because the server no longer computes it.
- Chunks are written with `bson.int32` for `n` and with `binary` subtype `0x00` for `data`. Task 2b already moved `read`, `write` and `update_md5` to the `v` field of the chunk wrapper.
- The files document stores `chunkSize` as int32 and `length` as int64 (issue #35).
- `gridfs_file:write(buf, offset, size)` keeps its overwrite semantics. Chunks that exist get `update`, as today, so untouched bytes stay. Only chunks that do not exist yet are inserted, through `col:insert`, which splits them into batches as Task 4 defines (issue #36). The existing `t/gridfs_write.t` overwrite tests must pass unchanged.
- `update_md5` stays, but `write` does not call it. The GridFS spec deprecated `md5`, so issue #37 is out of scope.
- Fix two old bugs. After a write makes the file longer, `write` sets `self.file_size` to the new length. `update_md5` reads only chunks `0` to `ceil(length / chunk_size) - 1`. If the length is an exact multiple of the chunk size, the old code reads one chunk too many.
- Add `TEST: write twice past end`. On a new file handle, `write("abc", 0)` and then `write("d", 3)` both succeed, and `read()` returns `abcd`. Add `TEST: md5 exact multiple`. With `chunkSize = 4` and an 8-byte file, `update_md5()` succeeds, and the stored `md5` equals `ngx.md5` of the 8 bytes. Add `TEST: large file split`. Set `wire.limits.max_message_size = 20000` and write a 100,000-byte file with `chunkSize = 4096`. `read()` returns the same bytes.
- Add `TEST: stored types` to `t/gridfs_write.t`. A decoded Lua number does not show its BSON type, so the test asks the server. `count({_id = id, chunkSize = {["$type"] = "int"}, length = {["$type"] = "long"}})` on the files collection gives `1`. The chunks collection gives the same count for `n` with `"int"` and `data` with `"binData"`.

- [ ] **Step 1:** Add the new tests of this task to `t/gridfs_write.t`. Remove the `--- SKIP` line from the unaligned read block in `t/api.t`. Keep every existing overwrite assertion as it is.
- [ ] **Step 2: Run** `prove t/gridfs.t t/gridfs_write.t t/api.t`. Expected: the new blocks FAIL, and the old blocks pass.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS on all four servers.
- [ ] **Step 5: Commit** `feat(gridfs): port to command API`.

### Task 14: Sessions and transactions

**Files:** Create `lib/resty/mongol/session.lua`. Modify `colmt.lua` and `wire.lua`. Test: `t/replset/txn.t`, which runs only in the `replset` job.

**Interfaces:**
- Produces: `conn:start_session() -> session`. The `lsid` is `{id = binary(16 random bytes, subtype 0x04)}`.
- Produces: `session:start_transaction()`, `session:commit_transaction() -> true | nil, err, reply` and `session:abort_transaction() -> true | nil, err, reply`. The commit and abort commands go to `admin`. A reply with `ok = 1` and a `writeConcernError` is a failure. The call returns `nil`, the error message and the reply, so that the caller can read `errorLabels`.
- Produces: unknown commit results, from the transactions specification:
  - The driver adds the label `UnknownTransactionCommitResult` to the commit reply in four cases. The cases are a socket error or timeout, error code 50 (`MaxTimeMSExpired`), and a reply whose `errorLabels` has `RetryableWriteError`. The fourth case is a `writeConcernError` with any code other than 79 (`UnknownReplWriteConcern`) and 100 (`UnsatisfiableWriteConcern`). MongoDB 4.4 and later add `RetryableWriteError` themselves, so the driver needs no list of retryable codes. Labels in the reply stay. After a socket error, the reply is `{ok = 0, errmsg = err, errorLabels = {"UnknownTransactionCommitResult"}}`.
  - The session keeps the same `txnNumber` after a failed commit. A second `commit_transaction()` sends `commitTransaction` again with the same `txnNumber` and `writeConcern = {w = "majority", wtimeout = 10000}`.
  - After a socket error, the caller calls `conn:connect()` with no arguments on the same `conn`. It reuses the host, port and `opts` of the last successful `connect`, including the TLS options (Task 8). Login state belongs to the socket, so the caller then calls `db:auth()` again, as after any new connection. Then the caller calls `commit_transaction()` again. The README shows this pattern.
- Produces: the session path, with one new optional argument for each method:
  - `col:insert(docs, continue_on_error, safe, opts)`, `col:update(selector, update, upsert, multiupdate, safe, opts)` and `col:delete(selector, single_remove, safe, opts)`.
  - `col:query(..., options)` reads `options.session` from its existing fifth argument. `col:getmore(cursorID, numberToReturn, offset_i, opts)` and `col:kill_cursors(ids, opts)` get a new last argument.
  - `col:find(query, fields, num_each, opts)`, `col:find_one(query, fields, opts)` and `col:aggregate(pipeline, options)` read `session` from the last argument. A cursor stores the session and passes it to the first `query`, to every `getmore` and to `close`.
  - `wire.command(conn, dbname, cmd, sequences, session)` and `wire.send_only` get the session as their last argument. With a session, `wire.command` calls `session:fields()`. This returns an ordered list of `{key, value}` pairs and does not change `cmd`. The list has `lsid`. In a transaction, it also has `txnNumber` (int64), `autocommit = false`, and `startTransaction = true` on the first command. `wire.command` adds these pairs to the encoded bytes after `cmd`, as Task 3 does for `$db`.
- Produces: outside a transaction, a write with a session and an unsafe `safe` value (`nil`, `false` or `0`) returns `nil, "unacknowledged write with a session"` and sends nothing. The sessions specification does not allow `lsid` with `w = 0`.
- Produces: rules inside a transaction, from the MongoDB transactions specification:
  - Operations send no `writeConcern`. Only `commitTransaction` and `abortTransaction` carry one.
  - Any write is acknowledged and returns the safe-mode value, whatever `safe` is. The README documents this.
  - A cursor stores the session. Each `getMore` sends the same `lsid`, `txnNumber` and `autocommit = false`, without `startTransaction`.
- Add `TEST: txn read across batches`. Insert 25 documents in a transaction, then `find({}, nil, 10)` in the same transaction yields 25 documents before the commit.

- `session.lua` calls `wire.command(...)` through the module table, and does not cache it as a local. This is an exception to the caching rule in Global Constraints. The tests replace `wire.command` with a stub, and a cached local never sees the stub.
- Produces: while a transaction is open, `conn:set_keepalive()` returns `nil, "transaction in progress"`, as `lua-resty-redis` does.

- [ ] **Step 1: Write failing tests.** `TEST: commit visible` inserts in a transaction, commits, and gets `count == 1`. `TEST: abort invisible` inserts, aborts, and gets `count == 0`. `TEST: keepalive in txn` gets `nil` and `transaction in progress`. `TEST: two transactions` runs two committed transactions on one session. Both inserts are visible, and the second transaction sends a higher `txnNumber`. `TEST: mixed operations` starts a transaction and inserts with the session. Then it inserts without a session on the same connection, and aborts. `count == 1`, because only the insert without a session stays. `TEST: commit write concern error` replaces `wire.command` in the test with a stub that returns `{ok = 1, writeConcernError = {code = 64, errmsg = "waiting for replication timed out"}, errorLabels = {"UnknownTransactionCommitResult"}}`. `commit_transaction()` returns `nil`, the `errmsg`, and the reply with its `errorLabels`. `TEST: commit labels` uses stub replies without the label. Three replies get it: the `writeConcernError` with code 64, a `writeConcernError` with code 11602, and `{ok = 0, code = 91, errorLabels = {"RetryableWriteError"}}`. A `writeConcernError` with code 100 does not get it. `TEST: lost commit reply` uses a stub for the first `commitTransaction`. The stub calls the real `wire.command`, so the server commits. Then it closes the socket and returns `nil, "closed"`. The first commit returns `nil` and a reply with the label. After `conn:connect()` with no arguments, the second commit returns `true`, and `count == 1`. The stub records that both commits sent the same `txnNumber`, and that the second one sent `w = "majority"`. `TEST: session with unsafe write` calls `insert` with a session and `safe` set to `nil`, `false` and `0`. Each call returns `nil` and `unacknowledged write with a session`.
- [ ] **Step 2: Run** `make test-replset` in the `replset` job. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `make test-replset`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(session): transactions`. Tag the Phase 5 release.

---

## Phase 6: Release

### Task 15: Docs and packaging

**Files:** Modify `Readme.md`. Create `CHANGELOG.md`, `lua-resty-mongol-<version>-1.rockspec` and `dist.ini`.

- [ ] **Step 1:** Rename `Readme.md` to `README.markdown` with a table of contents, the OpenResty convention. Remove the "deprecated" line. Fix the `find_one` return description (issue #44). Add examples for `$or`, dot notation and pagination with `skip`, `limit` and `sort` (issues #13, #14, #26, #41, #48). Add the supported server versions and the `db:cmd` key-order rule. Add the login and pool pattern and `cursor:close()`. Add the number rule, its helpers and the new methods.
- [ ] **Step 2:** Add a `CHANGELOG.md` section for each release after `1.0.0`. Task 6 already wrote the `1.0.0` section. Add the removal of MONGODB-CR to the Phase 3 section.
- [ ] **Step 3:** Add the rockspec with `build.type = "builtin"` and every module under `lib/resty/mongol`. Add `dist.ini` for OPM with `name`, `abstract`, `author`, `is_original = no`, `license = mit`, `lib_dir = lib`, `doc_dir = lib`, `main_module = lib/resty/mongol/init.lua` and `repo_link`. OPM reads the version from `_VERSION` in the main module.
- [ ] **Step 4: Run** `luarocks lint lua-resty-mongol-*.rockspec` and `opm build`. Expected: no errors.
- [ ] **Step 5:** Reply to every open GitHub issue with the fixing release, or with the reason that it is out of scope. Use the table in "Issue and PR disposition". Then close it. Close each open PR with a thank-you and a link to the commit that supersedes it.
- [ ] **Step 6: Commit** `docs: README, CHANGELOG, packaging`.

---

## Issue and PR disposition

Open issues:

| Issue | Plan |
|---|---|
| #70, #71, #15 | Task 1 removes `module()` and the global writes |
| #47, #58, #63, #69, #33 | Task 1b |
| #12, #74 | Task 6 (`TEST: all documents`) |
| #16, #52 | Task 2 |
| #61, #72 | Tasks 3 to 5 (modern protocol, `count` command) |
| #45, #50, #56 | Task 7 |
| #32, #65 | Task 8 (TLS, pool options, README pool pattern) |
| #1, #14, #29, #59 | Task 2b |
| #53 | Task 2b (signed date wrapper) and Task 10 (JSON) |
| #66, #67 | Task 10 (JSON, empty arrays) |
| #41, #48, #54 | Task 6 (server sort, `skip`) |
| #55 | Task 11 |
| #10, #22 | Task 12 |
| #35, #36 | Task 13 (chunk inserts in batches through Task 4) |
| #13, #26, #44 | Task 15 (README) |
| #51 | Done by merged PR #62 (`find_and_modify`). Task 5 tests it. Close |
| #46 | Answer: iterate `cursor:next()`. Each call reads from the current batch, not from the server. Close |
| #38 | Answer: the server creates the collection on the first insert. Close |
| #37 | Out of scope. The GridFS spec deprecated `md5`. Close |
| #23 | Out of scope. Renames break the API. Close |

Open PRs:

| PR | Plan |
|---|---|
| #60 `le_uint_to_num` speed-up | Superseded by Task 2 |
| #57, #40 array index fix | Superseded by Task 2b |
| #49 `ngx.worker.pid` | Superseded by Task 1b |
| #39 `bson_null` | Superseded by Task 2b |
| #20 lazy machine id, no `assert` | Superseded by Tasks 1b and 2 |
