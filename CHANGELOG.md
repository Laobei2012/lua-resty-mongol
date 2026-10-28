# Changelog

## Unreleased (Phase 5)

### Sessions and transactions

- `conn:start_session()` is new. It returns a session with an `lsid`. Pass it
  as `opts.session` (the last argument) of `col:insert`, `col:update`,
  `col:delete`, `col:query`, `col:getmore`, `col:kill_cursors`, `col:find`,
  `col:find_one` and `col:aggregate`. A bad session raises `bad argument`,
  also a session from another connection.
- `session:start_transaction()`, `session:commit_transaction()` and
  `session:abort_transaction()` are new (they need a replica set). They
  return `true`, or `nil, err` (commit and abort also return the reply as a
  third value). A transaction runs on the primary connection only: it
  ignores `conn.read_conn` and the read preference.
- Inside a transaction every write is acknowledged, whatever `safe` says, and
  returns the value of a safe write. The operations carry no write concern;
  only commit and abort do. A cursor keeps the session, so each `getMore` has
  the same `lsid` and `txnNumber`.
- Outside a transaction a write with a session and a false `safe` returns
  `nil, "unacknowledged write with a session"` and sends nothing.
- A commit that fails with a socket error, a timeout, error 50, a
  `RetryableWriteError` label, or a write concern error other than 79 and 100
  gets the label `UnknownTransactionCommitResult` in the reply. Commit again
  with `session:commit_transaction()`: it sends the same `txnNumber` with
  `w = "majority"`. After a socket error, call `conn:connect()` with no
  arguments (and `db:auth()` if you use a login) before you commit again.
- `session:abort_transaction()` ends the transaction whatever the result, so
  the session can start a new one.
- `conn:set_keepalive()` returns `nil, "transaction in progress"` while a
  transaction is open.
- `col:count` is not part of a transaction. It reads collection metadata and
  can count the documents of an open transaction; use an aggregation.

### GridFS

- `gridfs_file:read(size, offset)` honors the offset inside a chunk. Before,
  it started at the right chunk but took the bytes from the start of it.
  `size` defaults to the rest of the file and is cut at the end of the
  file. Reading an empty file returns `""`.
- `gridfs:get(fh, fields)` returns `true` (it returned the file handle), or
  `nil, err`.
- `gridfs_file:write(buf, offset, size)` sets `file_size` and `length` when
  the file gets longer, so a second write at the new end works. It returns
  the number of bytes written. Existing chunks are updated and the bytes
  around the written range stay. New chunks are inserted in batches that fit
  the server limits (issues #35 and #36).
- `gridfs_file:update_md5()` reads the chunks 0 to ceil(length / chunk size)
  - 1. It read one chunk too many when the length is a multiple of the
  chunk size. `write` still does not call it; the `md5` field is
  deprecated in the GridFS specification (issue #37 is out of scope).
- The files document stores `chunkSize` as int32 and `length` as int64
  (issue #35). The chunk documents store `n` as int32 and `data` as binary
  subtype 0.
- `gridfs:new(meta)` and `gridfs:insert(fh, meta, safe)` do not add `md5`,
  `uploadDate` and `length` to your `meta` table any more. They still set
  `_id`, `filename` and `chunkSize` in it. Reason: those three values belong
  to one stored file. If you reuse a `meta` table for a second file, the old
  `length` and `md5` of the first file would go with it. The driver builds the
  files document from a copy of the table.
- The chunks collection gets the unique index `{files_id: 1, n: 1}` from
  `new`, `insert` and `write` (once for each bucket object). The stored
  `length` only grows, an update that matches no chunk or file is an error,
  and two writers on the same bytes are last writer wins.
- `read` and `update_md5` check that chunks exist, hold binary data of
  subtype 0, and have the right length. `read` returns `nil, err` for a bad
  chunk, and `update_md5` returns `false, err`. `write` checks the binary
  type and subtype of existing chunks and returns `nil, err` for bad data.
- `new` and `insert` raise `bad argument` for a `chunkSize` that is not a
  positive whole number. `write` raises `bad argument` for arguments of the
  wrong type and returns `nil, "invalid size"` for a negative size.
- A new file has no `md5` field (it was `0`), and `write` removes the `md5`.
  Call `update_md5()` to store a digest.
- A failed query makes `write`, `remove`, `find_one` and `get` return
  `nil, err`. `remove` returned 0 before.

### Connection strings and replica sets

- `mongol.connect_uri(str)` is new (issues #10 and #22). It parses a
  `mongodb://` string, tries the seeds and the members that `hello` names,
  and returns a connection to the primary, or `nil, err`. Writes and
  `db:cmd` always use the primary. A user in the string logs in on
  `authSource` (the option, else the database of the string, else `admin`).
  `mongodb+srv://` is not supported. The `replicaSet` option is read but
  not checked.
- `readPreference` applies to reads only (`col:query`, `col:find`,
  `col:find_one`, `col:count` and `col:aggregate`):
  - `primary` (the default) and `primaryPreferred`: the primary serves the
    reads. If no primary answers, `connect_uri` returns `nil, err`.
  - `secondary`: a second connection, `conn.read_conn`, goes to a member
    that is a secondary. If there is none, `connect_uri` returns `nil, err`.
  - `secondaryPreferred`: the same, but the primary serves the reads if
    there is no secondary.
  - Any other value returns `nil, err`. Every command on `conn.read_conn`
    carries `$readPreference`, and the commands on the primary never do.
  - A secondary can be a little late, so a read right after a write can
    miss the document.
  - A cursor keeps the connection of its first query for `getMore` and
    `killCursors`. `conn:close()` and `conn:set_keepalive()` also act on
    `conn.read_conn`.
- `uri.parse(str)` (module `resty.mongol.uri`) returns `{hosts, db, user,
  password, options}` or `nil, err`. It decodes percent-encoding in the user
  name, the password and the database. Unescaped `@` or `:` in the user
  information, a bad port or a bad `tls` value is an error.
- With `tls=true` the handshake verifies the certificate against the host
  name. ngx_lua does not match a certificate name against an IP address, so
  use host names in the string when you use `tls=true`.
- `conn:connect()` with no arguments reconnects `conn.read_conn` too, keeps
  its read preference, and logs in again for a `connect_uri` connection with
  a user. `connect(host, port)` with an address closes and drops `read_conn`.
- A raw `col:getmore` and `col:kill_cursors` use the same connection as
  `col:query` (the secondary of a read preference).
- A repeated option in the string: the last one wins. A unix domain socket,
  an IPv6 literal that is not one, and a bad host are errors.
- The pool names that the driver makes (`plain:`, `tls:` and for a user in a
  string) have the length of each part in front of it, so two different
  settings never share a pool. `uri.parse_host` is the one parser for the
  string and for the members that `hello` names (`[::1]:27017` works).
- The `started` event of the monitor holds the fields that the driver adds
  after `$db`, such as `$readPreference`.
- `getprimary` and `connect_uri` now give the port of a member as a number.
  Before, `getprimary` gave a string, or an empty string for a member
  without a port.

### Command monitoring

- `mongol.set_monitor(m)` is new. `m` has the optional functions
  `started(ev)`, `succeeded(ev)` and `failed(ev)`, as in the MongoDB
  Command Logging and Monitoring specification. The driver sends no
  metrics itself. The `Readme.md` has a Prometheus example.
- Login commands, `createUser`, `updateUser` and a `hello` with
  `speculativeAuthenticate` are redacted: `command` and `reply` are empty
  and `failed.error` is `"redacted"`.
- A hook that raises an error is logged and does not change the result of
  the command. Without a monitor, each command does one check.
- `succeeded` means that the command succeeded, not that the write
  succeeded. A reply with `writeErrors` is a succeeded command.
- The `command` of an event is decoded from the bytes that the driver sent, so
  it has the keys that went on the wire. `bson.null` and empty arrays keep
  their meaning in events, and a hook cannot change the tables of the caller.

### Aggregation

- `col:aggregate(pipeline, options)` is new (issue #55). It returns a cursor
  over the results, or `nil, err`. The cursor has the same methods as the
  cursor of `col:find` (`next`, `pairs`, `close`). `options.batch_size`
  sets the batch size of each fetch and defaults to 100. A `pipeline` that
  is not a table raises `bad argument`.

## Unreleased (Phase 4)

### BSON types

- `bson.decimal128(str)` makes a Decimal128 value from a decimal string. It
  returns `nil, err` for a bad, inexact or out-of-range string. `tostring`
  of a value gives the decimal string, and `value.v` holds the 16 bytes.
  A read of type 0x13 returns the same wrapper. Before, it raised an error.
- `bson.regex(pattern, options)` makes `{pattern, options}`. It sorts the
  options. A read of type 0x0B returns the same wrapper. A `\0` in the
  pattern or the options makes `bson.to_bson` return `nil, "invalid regex"`.
- `bson.minkey()` and `bson.maxkey()` make the MinKey and MaxKey values,
  and reads of types 0xFF and 0x7F return them.
- No caller breaks: reads of these types raised an error before.

### JSON

- `bson.to_json_safe(doc)` returns a copy of a document that `cjson` can
  encode (issues #53, #66 and #67). `lua-cjson` does not call metamethods
  and raises on cdata. The copy has these values:
  - An ObjectId is a hex string. A date is an ISO 8601 string with
    milliseconds. `bson.null` is `cjson.null`.
  - An `int64_t` value (an integer above 2^53) is a decimal string, so that
    no digits are lost.
  - Binary data is a base64 string, and Decimal128 is its decimal string.
  - A Timestamp is `{t, i}`, and a regex is `{pattern, options}`. MinKey
    and MaxKey are the strings `"MinKey"` and `"MaxKey"`.
  - An empty array stays an array. The `int32`, `int64` and `double`
    wrappers become numbers.
- NaN and Infinity doubles become the strings `"NaN"`, `"Infinity"` and
  `"-Infinity"`, so that `cjson.encode` always works on the copy.
- A date above 2^53 keeps its milliseconds. A year outside 0000 to 9999
  has a sign and six digits (`+010000`, `-000001`), as in ISO 8601.
- A table that BSON stores as a document gets string keys in the copy.

## Unreleased (Phase 3)

### Authentication

- `db:auth(user, password)` asks the server for the mechanism of the user
  (`hello` with `saslSupportedMechs`). It uses SCRAM-SHA-256 if the server
  lists it, or if the list is missing or empty (for example, for a user
  that does not exist). It uses SCRAM-SHA-1 if the list has only that
  mechanism. It still returns `1`, or `nil, err`.
- SCRAM-SHA-256 needs an ASCII password. A password with other characters
  returns `nil, "non-ASCII password not supported"`, because full SASLprep
  is not implemented.
- `db:auth_scram_sha1(user, password)` keeps its name and uses SCRAM-SHA-1.
- A bad server reply (a wrong nonce or signature, a bad payload or salt)
  returns `nil, err` and closes the socket, so it never goes back to the
  pool.
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
  `get_reused_times()` to skip a second login. Give each user a separate
  pool name with the `pool` option of `connect`.

### Connection

- `conn:connect(host, port, opts)` takes an optional table `opts`:
  `pool`, `pool_size` and `backlog` go to the connection pool. `ssl`,
  `ssl_verify` (default `true`), `ssl_server_name` (default `host`) and
  `ssl_reused_session` control TLS. With `ssl`, `connect` returns the TLS
  session as a second value. The two-argument call does not change.
- `ssl_verify` needs `lua_ssl_trusted_certificate` in `nginx.conf`.
- A failed TLS handshake closes the socket and returns `nil, err`.
- With `ssl` and no `pool`, the default pool name holds the host, port, `ssl_verify` and `ssl_server_name`. A TLS socket is never reused by a plain or by a differently verified connection. A `pool` name that you give never equals a generated name. Use one pool name for one TLS setting.
- `connect` remembers the host, port and options of the last successful
  call. `conn:connect()` with no arguments uses them again.

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
