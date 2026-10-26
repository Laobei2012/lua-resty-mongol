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
- Phase 4 number rule (owner decision, Option B): a whole number that fits in int32 goes out as int32. A larger whole number that fits in int64 goes out as int64. Any other number goes out as a double. On read, an int64 above 2^53 returns as `int64_t` cdata.
- License: MIT/X11.
- Commit style: `type(scope): description`, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. A server that closes the socket or sends a short or invalid reply. Expected: the call returns `nil, err`, and the driver closes the socket so that `set_keepalive` cannot put a broken socket in the pool. Test: Task 3, `TEST: truncated reply`.
2. A cursor with `limit` that is not a multiple of the batch size, over more than one `getMore`. Expected: exactly `limit` documents, then `nil`. Test: Task 6, `TEST: limit across batches`.
3. Number edges: `2^31 - 1`, `2^31`, `-2^31 - 1`, `2^53 + 1` as cdata, `0.5`, `-0.0`, `1e300`, NaN. Expected: each value round trips with the type from the Phase 4 rule. Test: Task 10, `TEST: number edges`.
4. Strings with embedded `\0`, and binary data. Expected: an exact round trip for values. Keys with `\0` return `nil, err`. Test: Task 2, `TEST: nul in values`.
5. A pooled socket reused by a request that needs a different login. Expected: the README pattern with one pool name for each user works, and `get_reused_times()` lets the caller skip a second login. Test: Task 8, `TEST: pooled login reuse`.

---

## File Structure

| File | Responsibility | Phase |
|---|---|---|
| `LICENSE` | MIT/X11 text, with the original authors | 0 |
| `.github/workflows/test.yml` | CI matrix and service containers | 0, 3, 5 |
| `Makefile` | `test` target runs `prove -r t` | 0 |
| `t/lib/Mongol.pm` | Shared Test::Nginx setup: `$HttpConfig` and environment defaults | 0 |
| `lib/resty/mongol/init.lua` | Connection object. Local module table, no `module()` | 0, 1, 3 |
| `lib/resty/mongol/misc.lua` | `attachpairs_start` and a local `opairs` that honors `__pairs`. No `_G` write | 0 |
| `lib/resty/mongol/ll.lua` | Byte helpers, plus int64 encode and decode | 1 |
| `lib/resty/mongol/bson.lua` | BSON encode and decode, ordered docs, integer wrappers, types | 1, 4 |
| `lib/resty/mongol/wire.lua` (new) | `OP_MSG` encode, decode, send, receive | 1 |
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

- [ ] **Step 1: Write the failing test.** `t/globals.t`, `TEST 1: no global writes`. The test runs with `lua_code_cache on`, plus an `init_by_lua_block` that does `setmetatable(_G, {__newindex = function(_, k) error("global " .. k) end})`. The content block requires `resty.mongol`, calls `mongol:new()` and says `ok`. Expected `response_body`: `ok`. Expected: `--- no_error_log` of `[error]`.
- [ ] **Step 2: Run** `prove t/globals.t`. Expected: FAIL. `module()` and `_G.pairs` write globals.
- [ ] **Step 3: Implement.** In `init.lua`, replace `module(...)` and the `getmetatable(resty.mongol).__newindex` block with `local _M = {}` and `return _M`. Keep `_M.new`. In `misc.lua`, delete the `_G.pairs` override and add `opairs`. In `bson.lua`, use `opairs` in `to_bson`.
- [ ] **Step 4: Run** `prove t/globals.t`. Expected: PASS.
- [ ] **Step 5: Add CI.** In `test.yml`, use `ubuntu-latest` with a matrix of `mongo: ["6.0", "7.0", "8.0", "9.0"]` and a `services.mongo` container on port 27017, without auth. Install OpenResty 1.31.1.1 from the OpenResty apt repo. Install Test::Nginx with `cpanm --notest Test::Nginx`. Then run `make test`. Set `permissions: contents: read`, and pin every third-party action by commit SHA. In `Makefile`, set `test` to `PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH prove -I t/lib -r t`, and make `install` honor `DESTDIR`. Move every `t/*.t` header to `use lib 't/lib'; use Mongol;`. Replace the literal ports and credentials in the tests with `$TEST_NGINX_MONGO_*`.
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
  - `t/objid.t`, `TEST: unique across workers`. With `worker_processes 2`, ids from two workers differ in bytes 5 to 9.
- [ ] **Step 2: Run** `prove t/objid.t t/globals.t`. Expected: FAIL.
- [ ] **Step 3: Implement** the interfaces above.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit** `fix(objectid): spec layout, no ngx.var, loadable in any phase`.

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
- Produces: array detection does not depend on `pairs` order (issue #52). Let `n` be the count of keys. If every key is an integer from 1 to `n`, the table is an array.
- Produces: `ll.num_to_le_uint` and `ll.num_to_le_int` return `nil, "number out of range"` and do not `assert` (issue #16, PR #20).

- [ ] **Step 1: Write failing tests** in `t/bson.t`:
  - `TEST: ordered keys`. `to_bson(bson.ordered{{"find","c"},{"filter",{}},{"limit",bson.int32(1)}})` has `find` as its first element name, and the element type of `limit` is `0x10`.
  - `TEST: int64 above 2^53`. Decoding the 8 bytes of `9007199254740993` gives `tostring(v) == "9007199254740993LL"`.
  - `TEST: nul in values`. The string `"a\0b"` round trips with a length of 3. The key `"a\0b"` returns `nil` and `invalid key`.
- [ ] **Step 2: Run** `prove t/bson.t`. Expected: FAIL.
- [ ] **Step 3: Implement** the interfaces above. For int64 bytes, use `ffi.new("int64_t[1]")` and `ffi.string(p, 8)`, because the target CPUs are little-endian.
- [ ] **Step 4: Run** `prove t/bson.t`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(bson): ordered documents and int32/int64 wrappers`.

### Task 3: OP_MSG transport and db:cmd

**Files:**
- Create: `lib/resty/mongol/wire.lua`
- Modify: `lib/resty/mongol/dbmt.lua:16-31`, `lib/resty/mongol/init.lua` (`ismaster`, `getprimary`, `databases`, `shutdown`)
- Test: `t/wire.t` (new)

**Interfaces:**
- Consumes: `bson.ordered`, `bson.to_bson`, `bson.from_bson`.
- Produces: `wire.command(conn, dbname, cmd, sequences) -> reply_doc | nil, err, reply_doc`.
  - `cmd` is an ordered document or a plain table. `wire.command` adds `$db = dbname` as the last key.
  - `sequences` is optional. It is a list of `{identifier, docs}` and becomes kind-1 sections.
  - If `reply.ok ~= 1`, the result is `nil, reply.errmsg, reply`.
  - On a socket or framing error, it calls `conn.sock:close()`, sets `conn.broken = true` and returns `nil, err`.
  - It accepts `flagBits` with bit 0 (`checksumPresent`) set, and drops the last 4 bytes.
  - It rejects reply opcodes other than 2013 with `nil, "unexpected opcode " .. op`.
- Produces: `db:cmd(q)` calls `wire.command(self.conn, self.db, q)`. It keeps the return values `doc` and `nil, errmsg, doc`.
- Produces: if `self.broken` is set, `conn:set_keepalive(...)` returns `nil, "closed"`.
- Produces: `conn:ismaster()` sends `{hello = 1}` and returns `r.isWritablePrimary, r.hosts`.

- [ ] **Step 1: Write failing tests** in `t/wire.t`:
  - `TEST: hello`. `conn:ismaster()` against `$TEST_NGINX_MONGO_HOST` returns `true`. The response body is `true`.
  - `TEST: cmd error`. `db:cmd({nosuchcmd = 1})` returns `nil` and a message that contains `no such command`.
  - `TEST: truncated reply`. Use `--- tcp_listen 12345` and `--- tcp_reply` with 10 bytes. `db:cmd({ping = 1})` returns `nil, err`, and `conn:set_keepalive()` returns `nil, "closed"`.
  - `TEST: checksum flag`. Use `--- tcp_reply` with a hand-built `OP_MSG` reply that has bit 0 set and `{ok = 1}` in the body. `db:cmd` returns a table with `ok == 1`.
- [ ] **Step 2: Run** `prove t/wire.t`. Expected: FAIL.
- [ ] **Step 3: Implement** `wire.lua`. Header: `messageLength`, `requestID`, `responseTo`, `opCode = 2013`. Body: `flagBits = 0`, section kind 0 with the command, then one kind-1 section for each sequence (`int32 size`, `cstring identifier`, docs). Keep the request id counter as a module upvalue.
- [ ] **Step 4: Run** `prove t/wire.t t/bson.t`. Expected: PASS on all four servers in CI.
- [ ] **Step 5: Commit** `feat(wire): send all commands as OP_MSG`.

---

## Phase 2: CRUD on commands

### Task 4: Writes (insert, update, delete)

**Files:**
- Modify: `lib/resty/mongol/colmt.lua:30-208` (delete the opcode table, `compose_msg`, `docmd`, `read_msg_header`, `handle_reply`)
- Test: `t/sanity.t` (existing tests, ported to `$TEST_NGINX_MONGO_*`), plus new blocks

**Interfaces:**
- Consumes: `wire.command`, `bson.ordered`, `bson.int32`.
- Produces: unchanged signatures. `col:insert(docs, continue_on_error, safe)`, `col:update(selector, update, upsert, multiupdate, safe)` and `col:delete(selector, single_remove, safe)`.
  - `insert` sends `insert`, with `documents` as a kind-1 sequence and `ordered = not truthy(continue_on_error)`. If the write is safe and succeeds, it returns `0`.
  - `update` sends `{q, u, upsert, multi}`. If the write is safe, it returns `reply.n`.
  - `delete` sends `{q, limit = single_remove and 1 or 0}`. If the write is safe, it returns `reply.n`.
  - If the write is unsafe, each call sends `writeConcern = {w = 0}` and returns `-1`.
  - If the reply has `writeErrors` or `writeConcernError`, the call returns `nil` and the first `errmsg`.
- Produces: `local function is_safe(v) -> boolean`. It returns `false` for `nil`, `false` and `0`.

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
  - It sends `find` with `filter`, `projection`, `skip` (int32), `limit` and `batchSize`. A negative `numberToReturn` means `singleBatch = true` with `limit = abs(n)`.
  - `options.sort` (new) becomes `sort`.
  - `cursor_id` is `ll.int64_to_le(reply.cursor.id)`. For an exhausted cursor, it is `"\0\0\0\0\0\0\0\0"`.
  - `flags` has `CursorNotFound = (code == 43)`, `QueryFailure = (any other error)` and `startingFrom`, `numberReturned`.
- Produces: `col:getmore(cursorID, numberToReturn, offset_i)` with the same return values. It sends `getMore = int64`, `collection` and `batchSize`.
- Produces: `col:kill_cursors(ids)` sends `killCursors` and returns `true | nil, err`.
- Produces: `col:count(query)` sends ordered `{count, query}` and returns `reply.n`.
- Produces: `db:listcollections()` returns a cursor built from the `listCollections` first batch. `db:add_user(u, p)` sends `createUser` with `roles = {}`.

- [ ] **Step 1: Write failing tests:**
  - `TEST: find_one`. Insert `{name="dog"}`. `find_one({name="dog"}).name` is `dog`.
  - `TEST: find_one miss`. The result is `nil`.
  - `TEST: count`. Insert 5 documents, then `count({})` gives `5`. This covers issue #61.
  - `TEST: query cursor not found`. `col:getmore("\1\0\0\0\0\0\0\0")` gives flags with `CursorNotFound == true`.
  - `TEST: listcollections`. After an insert into `c1`, the cursor yields a document with `name == "c1"`.
  - `TEST: find_and_modify`. Upsert `{x=1}` with `new=true`, and `.x` is `1`.
- [ ] **Step 2: Run** `prove t/sanity.t t/cursor.t`. Expected: FAIL.
- [ ] **Step 3: Implement** the interfaces above.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit** `feat(col): reads over find/getMore commands`.

### Task 6: Cursor

**Files:**
- Modify: `lib/resty/mongol/cursor.lua`
- Test: `t/cursor.t`

**Interfaces:**
- Consumes: `col:query`, `col:getmore`, `col:kill_cursors` from Task 5.
- Produces: `cursor:next() -> i, doc | nil | nil, err`. `cursor:limit(n)`, `cursor:skip(n)` (new), `cursor:sort(field, size)`, `cursor:close() -> true | nil, err` (new) and `cursor:pairs()`.
  - Before the first fetch, `sort` stores the sort in the cursor, fetches with server-side sort, and returns the first batch, as today.
  - After the first fetch, `sort` keeps today's client-side behavior.
  - Remove `cursor_mt.__gc`.

- [ ] **Step 1: Write failing tests** in `t/cursor.t`:
  - `TEST: limit across batches`. Insert 25 documents, then `find({}, nil, 10)` with `limit(23)` yields exactly 23 documents, then `nil`.
  - `TEST: all documents` (issue #74). Insert 2,500 documents. `find({}, nil, 100)` without a limit yields exactly 2,500 documents.
  - `TEST: skip`. Insert 10 documents with `n = 1..10`, then `sort({n=1})` and `skip(3)` give a first `n` of `4`.
  - `TEST: server sort`. Insert `n = 3, 1, 2`. `sort({n=-1})` returns `n` values in the order `3, 2, 1`.
  - `TEST: close`. After `close()`, `next()` returns `nil`.
  - `TEST: fetch error`. Drop the collection between batches with `num_each = 2`. `next()` eventually returns `nil, err` or ends without a Lua error.
- [ ] **Step 2: Run** `prove t/cursor.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `make test`. Expected: all blocks in `bson.t`, `wire.t`, `sanity.t`, `cursor.t` and `globals.t` PASS on all four servers. `gridfs*.t` and `cluster.t` can still fail. Mark them `--- SKIP` with the reason "Phase 5".
- [ ] **Step 5: Commit** `feat(cursor): server cursors, skip, close`. Tag the Phase 2 release.

---

## Phase 3: Authentication and connection

### Task 7: SCRAM-SHA-1 and SCRAM-SHA-256

**Files:**
- Create: `lib/resty/mongol/scram.lua`
- Modify: `lib/resty/mongol/dbmt.lua:45-187` (`auth`, `auth_scram_sha1`, the helper functions), `.github/workflows/test.yml`
- Test: `t/auth.t` (new)

**Interfaces:**
- Consumes: `wire.command`.
- Produces: `scram.authenticate(conn, dbname, user, password, mechanism) -> true | nil, err`, where `mechanism` is `"SCRAM-SHA-1"` or `"SCRAM-SHA-256"`.
  - SHA-1 uses `md5(user .. ":mongo:" .. password)` as the password, as today.
  - SHA-256 uses the SASLprep of the password. Bytes above 0x7F return `nil, "non-ASCII password not supported"`.
  - PBKDF2 and HMAC use FFI calls to `PKCS5_PBKDF2_HMAC` and `HMAC` in the OpenSSL that nginx links. At 15,000 iterations, pure Lua costs too much worker CPU. If the symbols are missing, the fallback is RFC 2104 HMAC over `resty.sha1` and `resty.sha256` (block size 64) with RFC 8018 PBKDF2.
  - The client nonce is 24 bytes from `resty.random.bytes(24, true)`, in base64.
  - The client checks that the server nonce starts with the client nonce, and checks the server signature `v=`.
  - It caches `salted_password` in a module table keyed by `mechanism .. user .. salt .. iterations`.
- Produces: `db:auth(user, password)` sends `hello` with `saslSupportedMechs = db .. "." .. user`. If the server lists SHA-256, it picks SHA-256. Otherwise, it picks SHA-1. `db:auth_scram_sha1(u, p)` stays as an alias.
- Produces: a CI job `auth`. It runs the four-version matrix with `MONGO_INITDB_ROOT_USERNAME=admin` and `MONGO_INITDB_ROOT_PASSWORD=admin`, and runs only `t/auth.t`.

- [ ] **Step 1: Write failing tests** in `t/auth.t`. Each test logs in against the `admin` database:
  - `TEST: sha256 login`. `auth("admin", "admin")` gives `1`. Then `insert(..., true)` gives `0`.
  - `TEST: sha1 login`. Create a user `u1` with `mechanisms = {"SCRAM-SHA-1"}`. `auth("u1", "p1")` gives `1`.
  - `TEST: wrong password`. The result is `nil` and a message that contains `Authentication failed`.
  - `TEST: rfc7677 vector`. Run `scram.lua`'s client proof over the RFC 7677 example (`user`, `pencil`, nonce `rOprNGfwEbeRWgbNEkqO`) and compare it with the RFC proof. No server is needed.
  - `TEST: pooled login reuse`. Request 1 logs in and calls `set_keepalive(10000, 10)`. Request 2 calls `connect` with the same `pool`, sees `get_reused_times() > 0`, skips login, and its `find_one` succeeds.
- [ ] **Step 2: Run** `prove t/auth.t` against a server with auth on. Expected: FAIL.
- [ ] **Step 3: Implement** the interfaces above.
- [ ] **Step 4: Run** `prove t/auth.t`. Expected: PASS in all four auth jobs.
- [ ] **Step 5: Commit** `feat(auth): SCRAM-SHA-256 with SHA-1 fallback`.

### Task 8: TLS, connect options, getprimary, ngx.var

**Files:**
- Modify: `lib/resty/mongol/init.lua` (`connect`, `getprimary`), every file that uses `ngx.var` (issue #58)
- Test: `t/connect.t` (new), `t/cluster.t`

**Interfaces:**
- Produces: `conn:connect(host, port, opts)`, modeled on `ledgetech/lua-resty-http` `connect(options)`. `opts` is optional.
  - `pool`, `pool_size` and `backlog` go to `sock:connect(host, port, {pool =, pool_size =, backlog =})`.
  - `ssl` (boolean), `ssl_verify` (default `true`), `ssl_server_name` (default `host`) and `ssl_reused_session` go to a separate `sock:sslhandshake(ssl_reused_session, ssl_server_name, ssl_verify)` call.
  - The old two-argument call does not change.
  - The README says that `ssl_verify` needs `lua_ssl_trusted_certificate`.
- Produces: `conn:getprimary()` uses `hello` and `isWritablePrimary`, with the same return values as today.

- [ ] **Step 1: Write failing tests:**
  - `TEST: pool option`. Two connects with `pool = "a"` show `get_reused_times() == 1` on the second.
  - `TEST: tls to plain server`. `connect(host, port, {ssl = true})` returns `nil, err` and raises no Lua error.
  - `TEST: pool_size`. `connect(host, port, {pool = "b", pool_size = 1})` succeeds.
- [ ] **Step 2: Run** `prove t/connect.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `make test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(conn): TLS and pool options, hello-based getprimary`. Tag the Phase 3 release.

---

## Phase 4: BSON correctness (new major version)

### Task 9: Number encoding (Option B)

**Files:**
- Modify: `lib/resty/mongol/bson.lua` (`pack`), `lib/resty/mongol/init.lua` (exports)
- Test: `t/bson.t`, `t/sanity.t`

**Interfaces:**
- Consumes: `bson.int32`, `bson.int64`, `bson.double`, `ll.int64_to_le`.
- Produces: `pack` for a plain Lua number `v`:
  - A finite value with `v == math.floor(v)` and `-2^31 <= v <= 2^31 - 1` is int32.
  - A finite whole number with `-2^63 <= v < 2^63` is int64.
  - Any other value, and `-0.0`, is a double.
  - `int64_t` cdata is int64.
- Produces: `mongol.int32`, `mongol.int64` and `mongol.double` on the module table returned by `require "resty.mongol"`.

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

  In `t/sanity.t`, `TEST: negative int32`: a safe insert of `{v = -1}` and a `find_one` give `v == -1` (issue #59).
- [ ] **Step 2: Run** `prove t/bson.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `make test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(bson)!: write whole numbers as int32/int64`. The body explains the breaking change.

### Task 10: Missing BSON types, empty arrays, JSON

**Files:**
- Modify: `lib/resty/mongol/bson.lua`, `lib/resty/mongol/object_id.lua`
- Test: `t/bson.t`

**Interfaces:**
- Produces: these constructors and their read types:

  | Constructor | BSON type |
  |---|---|
  | `bson.decimal128(str)` | `0x13`, read as the same wrapper, `tostring` gives the decimal string |
  | `bson.timestamp(t, i)` | `0x11`, read as `{t = , i = }` with the timestamp metatable |
  | `bson.regex(pattern, opts)` | `0x0B` |
  | `bson.minkey()` | `0xFF` |
  | `bson.maxkey()` | `0x7F` |
  | `bson.null` | `0x0A`, a sentinel that keeps a key on write |
  | `bson.empty_array` | `0x04`, an array with no elements |

- Produces: array indexes (issues #1, #14, #29, PRs #40, #57). Today a Lua array `{a, b}` is stored as `[null, a, b]`, and a stored array `[a, b]` reads back as `{[0] = a, b}`. The fix writes Lua index `i` as BSON key `i - 1`, and reads BSON key `k` as Lua index `k + 1`. OWNER DECISION PENDING: see the open question in the PR description.
- Produces: UTC dates read as signed int64, so that dates before 1970 are correct (issue #53).
- Produces: read of `0x0A` returns `bson.null`, not `nil`, so that the key stays (PR #39 idea, without its global `null`). This is a visible change, and it goes in `CHANGELOG.md`.
- Produces: ObjectId and UTC date wrappers have a `__tojson` metamethod. `bson.to_json_safe(doc)` returns a copy with ObjectId as a hex string and dates as ISO 8601 strings, for `cjson` (issues #53 and #67).

- [ ] **Step 1: Write failing tests.** `TEST: type round trip` for each row above, through a real insert and `find_one`. Also add `TEST: empty array stays array` for issue #66, and `TEST: cjson safe` with `cjson.encode(bson.to_json_safe(doc))`, which raises no error and contains the ObjectId hex.
- [ ] **Step 2: Run** `prove t/bson.t`. Expected: FAIL.
- [ ] **Step 3: Implement.** Decimal128 string conversion follows the BSON Decimal128 spec. Use the corpus files `decimal128-1.json` to `decimal128-7.json` from `mongodb/specifications`, `source/bson-corpus/tests`.
- [ ] **Step 4: Run** `make test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(bson): decimal128, timestamp, regex, min/max key, null, empty array`. Tag the new major release.

---

## Phase 5: New features

### Task 11: aggregate

**Files:** Modify `lib/resty/mongol/colmt.lua`. Test: `t/aggregate.t`.

**Interfaces:**
- Produces: `col:aggregate(pipeline, options) -> cursor | nil, err`. It sends ordered `{aggregate = col, pipeline, cursor = {batchSize = options.batch_size or 100}}` and returns a `cursor.lua` cursor on the reply (issue #55).

- [ ] **Step 1: Write the failing test.** `TEST: group sum`: insert `{k="a",v=1}`, `{k="a",v=2}` and `{k="b",v=5}`. Then `$group` by `k` with a sum of `v`, and `$sort` on `_id`, yield `a 3` and `b 5`.
- [ ] **Step 2: Run** `prove t/aggregate.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(col): aggregate`.

### Task 12: Replica set CI, primary selection, URI

**Files:** Create `lib/resty/mongol/uri.lua`. Modify `init.lua` and `.github/workflows/test.yml`. Test: `t/uri.t`, `t/cluster.t`.

**Interfaces:**
- Produces: `uri.parse(str) -> {hosts = {{host, port}}, db, user, password, options = {authSource, tls, replicaSet, readPreference}} | nil, err`. It decodes percent-encoding in the user name and the password.
- Produces: `mongol.connect_uri(str) -> conn | nil, err`. It connects to the first host that answers `hello`, then applies `readPreference` (issues #10 and #22):
  - `primary`: follow `getprimary()`.
  - `primaryPreferred`: use the primary. If no primary answers, use a secondary.
  - `secondary`: use a host whose `hello` reply has `secondary = true`. If none answers, return `nil, err`.
  - `secondaryPreferred`: use a secondary. If none answers, use the primary.
  - For a non-primary read preference, `wire.command` adds `$readPreference = {mode = ...}`, which `mongos` needs.
  - If the URI has a user, it logs in.
- Produces: a CI job `replset`. It runs `docker run -d --name rs -p 27017:27017 mongo:${{ matrix.mongo }} --replSet rs0`, then `docker exec rs mongosh --eval 'rs.initiate()'`, and waits for `isWritablePrimary`.

- [ ] **Step 1: Write failing tests.** `TEST: uri parse`, with `mongodb://u%40x:p@h1:1,h2/db?authSource=admin&tls=true&replicaSet=rs0`, gives the user `u@x`, two hosts, and `tls == true`. `TEST: connect_uri replset` against the `replset` job gives `ismaster() == true`.
- [ ] **Step 2: Run** `prove t/uri.t t/cluster.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(conn): mongodb:// URIs and replica set primary selection`.

### Task 13: GridFS on the new methods

**Files:** Modify `lib/resty/mongol/gridfs.lua` and `gridfs_file.lua`. Test: `t/gridfs.t`, `t/gridfs_write.t` (remove the Phase 5 skips).

**Interfaces:**
- Produces: the 8 README GridFS methods with unchanged signatures: `find_one`, `remove`, `get`, `insert`, `new`, `read`, `write` and `update_md5`. `update_md5` stays client-side with `resty.md5`, because the server no longer computes it.
- Chunks are written with `bson.int32` for `n` and with `binary` subtype `0x00` for `data`.
- The files document stores `chunkSize` as int32 and `length` as int64 (issue #35).
- `gridfs_file:write` inserts all chunks of one call in one `insert` command, as a kind-1 sequence (issue #36).
- `update_md5` stays, but `write` does not call it. The GridFS spec deprecated `md5`, so issue #37 is out of scope.
- Add `TEST: chunkSize is int32` to `t/gridfs_write.t`. Read the files document with `db:cmd` and check the type byte of `chunkSize`.

- [ ] **Step 1:** Remove the `--- SKIP` lines from `t/gridfs*.t`. Port the literal values to `$TEST_NGINX_MONGO_*`.
- [ ] **Step 2: Run** `prove t/gridfs.t t/gridfs_write.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS on all four servers.
- [ ] **Step 5: Commit** `feat(gridfs): port to command API`.

### Task 14: Sessions and transactions

**Files:** Create `lib/resty/mongol/session.lua`. Modify `colmt.lua` and `wire.lua`. Test: `t/txn.t`, which runs only in the `replset` job.

**Interfaces:**
- Produces: `conn:start_session() -> session`. The `lsid` is `{id = binary(16 random bytes, subtype 0x04)}`.
- Produces: `session:start_transaction()`, `session:commit_transaction() -> true | nil, err` and `session:abort_transaction() -> true | nil, err`. The commit and abort commands go to `admin`.
- Produces: an optional last argument `opts` with `opts.session` on `insert`, `update`, `delete`, `query`, `find_one` and `aggregate`. With a session, `wire.command` adds `lsid`. In a transaction, it also adds `txnNumber` (int64), `autocommit = false`, and `startTransaction = true` on the first command.

- Produces: while a transaction is open, `conn:set_keepalive()` returns `nil, "transaction in progress"`, as `lua-resty-redis` does.

- [ ] **Step 1: Write failing tests.** `TEST: commit visible` inserts in a transaction, commits, and gets `count == 1`. `TEST: abort invisible` inserts, aborts, and gets `count == 0`. `TEST: keepalive in txn` gets `nil` and `transaction in progress`.
- [ ] **Step 2: Run** `prove t/txn.t` in the `replset` job. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(session): transactions`. Tag the Phase 5 release.

---

## Phase 6: Release

### Task 15: Docs and packaging

**Files:** Modify `Readme.md`. Create `CHANGELOG.md`, `lua-resty-mongol-<version>-1.rockspec` and `dist.ini`.

- [ ] **Step 1:** Rename `Readme.md` to `README.markdown` with a table of contents, the OpenResty convention. Remove the "deprecated" line. Fix the `find_one` return description (issue #44). Add examples for `$or`, dot notation and pagination with `skip`, `limit` and `sort` (issues #13, #14, #26, #41, #48). Add the supported server versions and the `db:cmd` key-order rule. Add the login and pool pattern and `cursor:close()`. Add the number rule, its helpers and the new methods.
- [ ] **Step 2:** Write `CHANGELOG.md` with one section for each phase release. List every visible change: the int32 and int64 encoding, `bson.null` on read, no `__gc` cursor kill, the removal of MONGODB-CR, and int64 cdata above 2^53.
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
| #59 | Task 9 |
| #1, #14, #29, #53, #66, #67 | Task 10 |
| #41, #48, #54 | Task 6 (server sort, `skip`) |
| #55 | Task 11 |
| #10, #22 | Task 12 |
| #35, #36 | Task 13 |
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
| #57, #40 array index fix | Superseded by Task 10 |
| #49 `ngx.worker.pid` | Superseded by Task 1b |
| #39 `bson_null` | Superseded by Task 10 |
| #20 lazy machine id, no `assert` | Superseded by Tasks 1b and 2 |
