# Changelog

## 1.0.0 (unreleased)

This is the first release since the driver moved to the `OP_MSG` wire
protocol. MongoDB 5.1 and later reject the legacy opcodes, so the old
version does not work with MongoDB 6.0 to 9.0. This section lists every
change that a caller can see in Phase 0 and Phase 1, with the reason.
Later phases add their own entries.

### Server support

- The driver sends only `OP_MSG`. It works with MongoDB 6.0, 7.0, 8.0 and
  9.0. MongoDB 5.0 and earlier are not supported.
- `conn:ismaster()` keeps its name and its return values, but sends
  `hello` and reads `isWritablePrimary`. Reason: `ismaster` is deprecated.

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
  failure. It no longer returns a fourth value, the flags table. Reason:
  `OP_MSG` replies have no flags.
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
