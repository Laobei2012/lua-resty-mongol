# Changelog

## Unreleased (Phase 3)

### Authentication

- `db:auth(user, password)` asks the server for the mechanism of the user
  (`hello` with `saslSupportedMechs`). It uses SCRAM-SHA-256 if the server
  lists it, and SCRAM-SHA-1 if not. It still returns `1`, or `nil, err`.
- SCRAM-SHA-256 needs an ASCII password. A password with other characters
  returns `nil, "non-ASCII password not supported"`, because full SASLprep
  is not implemented.
- `db:auth_scram_sha1(user, password)` keeps its name and uses SCRAM-SHA-1.
- The client checks the server nonce and the server signature. A wrong
  value returns `nil, "server nonce mismatch"` or `nil, "server signature
  mismatch"`. The old SCRAM-SHA-1 code compared a boolean with a string,
  so it never rejected a bad nonce. It also used `math.random` for the
  nonce. The new code uses `resty.random`.
- The salted password is cached in the worker, so pooled connections skip
  PBKDF2.
- MONGODB-CR (`getnonce`) is removed. MongoDB 4.0 and later do not
  support it.
- Login state belongs to the socket, as before. After `set_keepalive`, a
  reused socket stays logged in as the same user. Use
  `get_reused_times()` to skip a second login, and do not share a socket
  between users.

## 1.0.0 (unreleased)

This is the major release that contains every breaking change of the
move to the `OP_MSG` wire protocol. The old version sends legacy opcodes
that MongoDB 5.1 and later reject. This section lists every change that a
caller can see, with the reason. Phase 3 and later add their own entries.

### Command transport

- `db:cmd` and the connection commands (`hello`, `listDatabases`,
  `dropDatabase`, `shutdown`) send `OP_MSG`.
- `conn:ismaster()` keeps its name and its return values, but sends
  `hello` and reads `isWritablePrimary`. Reason: `ismaster` is deprecated.

### Collection operations

- `col:insert`, `col:update`, `col:delete`, `col:query`, `col:getmore`,
  `col:kill_cursors`, `col:count`, `col:find_one` and `col:find_and_modify`
  send commands (`insert`, `update`, `delete`, `find`, `getMore`,
  `killCursors`, `count`, `findAndModify`). Arguments and return values
  stay the same, except for the changes below.
- `safe`, `continue_on_error`, `upsert`, `multiupdate` and `single_remove`
  follow the README: `nil`, `false` and `0` are false, and any other value
  is true. A write with `safe` false uses `writeConcern {w = 0}` and
  returns `-1`. A safe insert returns `0`. A safe update or delete returns
  `n`.
- A write error or a write concern error returns `nil` and the first
  server error message.
- `col:insert` splits a large call into batches that fit the server
  limits. A document over 16 MiB returns `nil, "document too large"`, and
  nothing is sent.
- `col:update` and `col:delete` raise `bad argument` if the selector is not
  a table, and `col:update` does the same for the update document. Before,
  a `nil` selector matched every document. Reason: a typo must not delete
  or change the whole collection.
- `col:query` and `col:getmore` return the same three values. A server
  error adds the message as a fourth value, and the flags table has
  `CursorNotFound` (error code 43) or `QueryFailure`. A socket or
  protocol error returns `nil, err`.
- `col:find_one` returns `nil, err` on a socket or server error.
- `col:find_and_modify` raises `bad argument` if `query` or `update`/`remove`
  is missing, does not change your options table, and returns `nil` when
  the document is not found.
- `col:count` works on current servers (issue #61).
- `db:add_user` works. It sends `createUser` with no roles.
- `db:listcollections()` and `db:list()` work on current servers and
  return a cursor. Both take an optional batch size.
- `db:list()` is the method that the README documents. It did not exist
  before.
- `col:kill_cursors` and `conn:shutdown()` work. Before, they sent
  malformed messages or raised.

### Cursors

- `col:find` yields every matching document across batches (issues #12
  and #74). Before, a cursor stopped after the first batch.
- `num_each_query` is only the batch size. `cursor:limit(n)` is the total
  limit. Before, `num_each_query` also limited the result.
- `cursor:sort(field)` before the first fetch sorts all documents on the
  server and returns the first batch. Before, it sorted only the first
  batch on the client. After the first fetch it sorts the rest of the
  current batch on the client, as before.
- `cursor:skip(n)` is new. `cursor:skip(n)` and `cursor:limit(n)` must come
  before the first fetch. After that they return `nil, "cursor already
  started"`.
- `cursor:close()` is new. It sends `killCursors`.
- The cursor has no `__gc` finalizer. A finalizer cannot use cosockets, so
  it cannot kill the cursor. Call `cursor:close()` when you stop before the
  end. If you do not, the server removes the cursor after its idle timeout
  (10 minutes by default).
- If a fetch fails, `cursor:next()` returns `nil, err`. A lost cursor
  (error code 43 or 175) no longer runs the query again, which could
  return a document twice.

### Numbers

- A whole number that fits in int32 is stored as int32. A larger whole
  number that fits in int64 is stored as int64. Any other number, and
  `-0.0`, is stored as a double. Before, every number was a double.
  Reason: this is what the official drivers do, and servers reject
  doubles where an integer is required (`limit`, `skip`, `batchSize`).
- `mongol.int32(n)`, `mongol.int64(n)` and `mongol.double(n)` force a type.
- On read, int32 and int64 values return as Lua numbers. An int64 value
  above 2^53 returns as LuaJIT `int64_t` cdata, so that no digits are lost.
- Negative int32 values read correctly (issue #59).
- Stored data: numbers that you stored as doubles keep their type. New
  writes of whole numbers use an integer type. Queries match both.

### Arrays

- Arrays use 1-based Lua indexes on write and read. Before, `{a, b}` was
  stored as `[null, a, b]`, and a stored `[a, b]` read as `{[0] = a, b}`.
  Reason: this fixes issues #1, #14 and #29.
- Stored data: arrays that the old version wrote have a leading `null`.
  They read back shifted by one. Fix them with an update before you
  upgrade.
- A table with the keys 1 to n is an array. An empty table is a document.
  Any other table is a document, and number keys become string keys.
  Before, such a table was stored as `_keys` and `_vals`.
- `bson.empty_array` writes an empty array. Use it for fields such as
  `roles` in `createUser` (issue #66).
- Every array that is read has the metatable `bson.array_mt`, so an empty
  array stays an array when you write it back.

### Null, dates, binary and timestamps

- A BSON null reads as `bson.null`, not `nil`. The key or array position
  stays. `if doc.x then` is now true for a null field. Write
  `doc.x ~= nil and doc.x ~= bson.null` to test for a value.
- A UTC date reads as a wrapper `{v = ms}` with a signed value, so dates
  before 1970 are correct (issue #53). Before, it read as a plain number.
- Binary data reads as a wrapper `{v = bytes, st = subtype}`. Before, it
  read as a plain string. `bson.get_bin_data(data, subtype)` takes an
  optional subtype. GridFS reads chunk bytes from `v`.
- A Timestamp reads as a wrapper `{t = seconds, i = increment}`. Before,
  it read as one int64 number. `bson.timestamp(t, i)` writes one.

### Errors

- `bson.to_bson` returns `nil, err` for a bad key (a `\0` in the key, or a
  key that is not a string or a number). It does not raise.
- `ll.num_to_le_uint` and `ll.num_to_le_int` return `nil, "number out of
  range"` (issue #16).
- A bad BSON document in a reply, or a socket or framing error, returns
  `nil, err`. The driver closes the socket, and `conn:set_keepalive()`
  returns `nil, "closed"`, so a broken socket never enters the pool. The
  next `conn:connect()` makes a new socket.
- `db:cmd(q)` returns the reply on success, or `nil, errmsg, reply` on
  failure. It no longer returns the fourth value, the old `OP_REPLY` query flags
  table. Reason: the driver does not use `OP_REPLY` any more.
- A command with more than one key needs the command name first. Build it
  with `bson.ordered({{"name", value}, ...})`.
- `conn:shutdown()` returns `true` when the server closes the socket, and
  `nil, err` on another error. Before, it raised a Lua error.
- `conn:databases()` returns `nil, err` on failure. Before, it raised.
- `db:dropDatabase()` sends `dropDatabase = 1`, which current servers
  need.

### Connection and ObjectId

- `require "resty.mongol"` no longer writes Lua globals (issues #70, #71,
  #15). The library no longer overrides `pairs`.
- `mongol:new()` makes no socket, so it works in `init_by_lua`. The socket
  is made by `conn:connect()`. `conn:set_timeout()` before `connect()`
  stores the value and returns `true` (issue #69).
- ObjectId follows the current BSON spec: 4-byte time, 5 random bytes for
  each process, 3-byte counter. The module no longer calls `ngx.var`,
  `io.popen` or `uname`, so it loads in timers and `init_by_lua` (issues
  #47, #58, #63). `get_hostname()` and `get_pid()` keep their names but
  read the bytes at the old positions.
- `object_id.new()` returns `nil, err` if `resty.random` fails.
  `object_id.new(str)` returns `nil, err` for a string that is not 12
  bytes. Before, both raised.
- `object_id.new_from_hex(hex)` is new (issue #33).

### Packaging and tests

- Add a `LICENSE` file (MIT/X11).
- Tests use Test::Nginx and read the server from `TEST_NGINX_MONGO_HOST`,
  `TEST_NGINX_MONGO_PORT`, `TEST_NGINX_MONGO_USER` and
  `TEST_NGINX_MONGO_PASS`.

### Not in this release yet

- `db:auth` still uses the old login. SCRAM login comes in Phase 3, so run
  the test server without authentication until then.
- GridFS `gridfs_file:read` with an offset inside a chunk, and
  `gridfs:get`, are fixed in a later phase.
- Replica set features (read preference, sessions) come in a later phase.
