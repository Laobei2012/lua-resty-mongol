# Modernize lua-resty-mongol for MongoDB 6.0 to 9.0

Date: 2026-10-25
Status: draft for review

## Intent

This repo is a MongoDB driver for OpenResty. It uses ngx_lua cosockets (non-blocking sockets inside nginx). The last real change was in January 2019. The README marks it as deprecated.

The owner wants to maintain it again. Current MongoDB servers reject the driver. MongoDB 5.1 and later accept only the `OP_MSG` and `OP_COMPRESSED` opcodes. The driver sends `OP_QUERY`, `OP_INSERT`, `OP_UPDATE`, `OP_DELETE`, `OP_GET_MORE` and `OP_KILL_CURSORS`. It also uses the `getlasterror` command for acknowledged writes.

Nobody knows which code depends on the driver today. For this reason, the refresh keeps the public API that the README documents.

## Goals

1. The driver works against MongoDB 6.0, 7.0, 8.0 and 9.0. Version 9.0.4 is the latest release on 2026-10-25.
2. Code that uses the documented API runs without changes.
3. Each phase ships on its own and leaves the driver usable.
4. CI runs Test::Nginx against a MongoDB container for each supported version.
5. The open GitHub issues that are in scope get fixes or a written reason.

## Non-goals

1. Support for MongoDB 5.0 and earlier.
2. `OP_COMPRESSED` and wire compression.
3. Client-side field level encryption and Queryable Encryption.
4. Topology monitoring in the background, as the official drivers do it.
5. A new API style that replaces the current one.

## Anti-goals

Even with all tests green, any of these makes the refresh a failure:

1. A documented call changes its arguments or its return values without a written reason in `CHANGELOG.md`.
2. Any call blocks the nginx worker. All network I/O must use cosockets.
3. The library writes to Lua globals. Issue #70 reports this today.
4. A protocol error or a server error raises a Lua error where the README promises `nil, err`.

## Constraints

1. Runtime: OpenResty LuaJIT, with Lua 5.1 semantics.
2. Dependencies: only Lua libraries that ship with OpenResty, for example `resty.sha256`, `resty.random` and `resty.string`. No C modules.
3. License: MIT/X11, inherited from `daurnimator/mongol`. A `LICENSE` file must be added.
4. Location: this repo, `Laobei2012/lua-resty-mongol`. The owner has admin rights. Work happens on feature branches with pull requests.
5. Tests: Test::Nginx, in `t/*.t`, run in GitHub Actions with MongoDB as a service container.

## Decisions by the owner

1. Keep the current API.
2. Support MongoDB 6.0 to 8.0, and also the latest release, which is 9.0.
3. Deliver all features in phases.
4. Keep the work in this repo.
5. Test with Test::Nginx and a MongoDB container in CI.

## Current state (read from the code)

1. `init.lua` uses `module("resty.mongol", package.seeall)`. This is the source of the global variable warning in issue #70.
2. `colmt.lua` builds legacy opcodes and parses `OP_REPLY`. It uses `assert` on socket and protocol errors.
3. `dbmt.lua` runs commands as `OP_QUERY` on `<db>.$cmd`. `auth()` uses MONGODB-CR (`getnonce`), which MongoDB removed in 4.0. `auth_scram_sha1()` exists, but it uses `math.random` for the nonce. Its nonce check is also wrong: `not a == b` is always false.
4. `listcollections()` reads `system.namespaces`, and `add_user()` writes to `system.users`. Current servers support neither.
5. `cursor.lua` sorts on the client after it fetches one batch. It has no `skip`.
6. `bson.lua` writes all Lua numbers as doubles. It reads int64 as a Lua number, which loses precision above 2^53. It reads type 17 (Timestamp) as int64. It does not know Decimal128, Regex, MinKey or MaxKey. It writes an empty table as an empty document, not as an empty array (issue #66).
7. The tests in `t/` expect a local `mongod` on port 27017 with user `admin`/`admin`.

## Phases

Each phase ends with green CI on all four server versions and a tagged release.

### Phase 0: Baseline and CI

1. Add `LICENSE` (MIT/X11, with the original authors).
2. Add a GitHub Actions workflow. Matrix: MongoDB 6.0, 7.0, 8.0, 9.0. It installs OpenResty and Test::Nginx and runs `prove -r t`.
3. Make the tests read the host, port, user and password from environment variables.
4. Replace `module(...)` with a local module table. `require "resty.mongol"` still returns an object with `:new()`.
5. Record which tests fail. All tests are expected to fail at this point.

Phase 0 is the one exception to the green CI rule. Its exit gate is a CI run that starts all four servers and reports the test results.

CI runs `mongod` without auth in Phases 0 to 2. From Phase 3, CI runs a second job with auth on.

### Phase 1: Wire protocol

1. Add `OP_MSG` encode and decode: section kind 0 (body) and kind 1 (document sequence). Checksums are not sent. The driver must accept a reply that has the `checksumPresent` flag set.
2. Send every command as `OP_MSG`, with `$db` in the body.
3. `db:cmd()` keeps its current return values: `doc` on success, or `nil, errmsg, doc` on failure.
4. Replace `ismaster` with `hello`. `conn:ismaster()` keeps its name and its return values.
5. Replace `assert` in the socket and protocol code with `nil, err` returns.
6. Add int32 and int64 encode helpers and an int64 decode helper. Phase 1 needs them, because `getMore` takes the cursor id as int64 and `limit`, `skip` and `batchSize` must be integers. Cursor ids stay as 8-byte strings in the public API.
7. OP_MSG needs the command name as the first key. Internal commands use an ordered builder, as `attachpairs_start` does today. The public `db:cmd(t)` keeps its current rule. A table with one key works as is. A table with more keys needs `attachpairs_start`. The README will say this.

### Phase 2: CRUD on commands, same API

| Old call | New command | Compatibility rule |
|---|---|---|
| `col:insert(docs, continue_on_error, safe)` | `insert` | `ordered = not continue_on_error`. If `safe` is falsy, use `writeConcern {w = 0}` and return `-1`. If `safe` is true, return `0` on success, as the README documents. |
| `col:update(sel, upd, upsert, multi, safe)` | `update` | If `safe` is true, return `n`. Otherwise, return `-1`. |
| `col:delete(sel, single, safe)` | `delete` | Same as `update`. |
| `col:query(...)` and `col:getmore(...)` | `find` and `getMore` | Return the same three values: an 8-byte cursor id string, a results table, and a flags table. |
| `col:kill_cursors(ids)` | `killCursors` | No change for callers. |
| `col:count(q)` | `count` | Fixes issue #61. |
| `col:find_one(q, fields)` | `find` with `limit 1` and `singleBatch` | No change for callers. |
| `db:listcollections()` | `listCollections` | Returns a cursor, as today. |
| `db:add_user(u, p)` | `createUser` | Same arguments. |
| `cursor:sort(...)` | Before the first fetch, `sort` on the server | Keeps the current return value. If results are already loaded, the client-side sort stays as the fallback. |

Add `cursor:skip(n)`, which is a TODO in the code today.

Rules for Phase 2:

1. `safe` follows the README. The values `nil`, `false` and `0` mean unacknowledged (`w = 0`). Any other value means acknowledged.
2. The flags table from `query` and `getmore` keeps its keys. If the server returns error code 43 (`CursorNotFound`), the driver sets `t.CursorNotFound = true`. If the server returns any other command error, the driver sets `t.QueryFailure = true` and also returns the error message.
3. If a fetch fails, `cursor:next()` returns `nil, err`.
4. The `__gc` finalizer no longer kills the cursor, because a finalizer cannot use cosockets. A new `cursor:close()` sends `killCursors`. If a caller does not close a cursor, the server removes it after its idle timeout (10 minutes by default).

If the server reports `writeErrors` or `writeConcernError`, the write returns `nil` and the server error message.

### Phase 3: Authentication and connection

1. Add SCRAM-SHA-256, with SASLprep for ASCII passwords. Non-ASCII passwords return a clear error until full SASLprep exists.
2. `db:auth(user, password)` asks the server for the mechanism through `hello` with `saslSupportedMechs`. It prefers SCRAM-SHA-256 and falls back to SCRAM-SHA-1.
3. Fix the SCRAM-SHA-1 nonce check, and use `resty.random` for the nonce.
4. Cache the salted password for each user, salt and iteration count in the worker. This keeps PBKDF2 off the hot path for pooled connections.
5. Add TLS through `sock:sslhandshake()`.
6. `conn:getprimary()` uses `hello`.
7. Remove the use of `ngx.var` (issue #58).
8. Auth state belongs to the socket, as today. After `set_keepalive`, a reused socket stays logged in as the same user. Callers use `get_reused_times()` to skip a second login, which is the current pattern. Each user must use a separate pool name, through the `pool` option of `connect`. The README will say this.

### Phase 4: BSON correctness

1. Numbers follow the official drivers (owner decision, Option B). A whole number that fits in int32 is written as int32. A larger whole number that fits in int64 is written as int64. Any other number is written as a double. A new helper `mongol.double(n)` forces a double. The helpers `mongol.int32(n)` and `mongol.int64(n)` force an integer type.
2. On read, int32 and int64 values return as Lua numbers. If an int64 value is larger than 2^53, it returns as LuaJIT `int64_t` cdata, so that no digits are lost.
3. This change alters the stored type for existing callers. `CHANGELOG.md` must describe it, and the release that contains it gets a new major version.
4. Add Decimal128, Timestamp, Regex, MinKey, MaxKey and the Null round trip.
5. Add a marker for an empty array (issue #66).
6. Fix negative int32 values (issue #59).
7. Let ObjectId and UTC dates convert to JSON through `cjson` (issues #53 and #67).

Phase 4 changes how values are decoded. Any change that a caller can see goes in `CHANGELOG.md`.

### Phase 5: New features

1. `col:aggregate(pipeline, options)`, which returns a cursor (issue #55).
2. Replica set connection with read preference `primary` and `primaryPreferred`.
3. GridFS on the new commands. Only the GridFS methods that the README documents keep their API.
4. Sessions and transactions: `lsid`, `txnNumber`, `startTransaction`, `commitTransaction` and `abortTransaction`. CI adds a single-node replica set for these tests.
5. Connection string parsing: `mongodb://` URIs, with `authSource`, `tls` and `replicaSet`.

### Phase 6: Release

1. Rewrite the README. Remove the "deprecated" notice.
2. Add a LuaRocks rockspec and an OPM `dist.ini`.
3. Add `CHANGELOG.md` and close or answer each open issue.

## Left to the builder

1. The exact OpenResty version in CI. Pin one current release.
2. The file layout for the new protocol code.
3. How to install Test::Nginx in CI.
4. Version numbers for each phase release.
5. Test names and how the tests are split across files.
