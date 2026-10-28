# lua-resty-mongol

An OpenResty MongoDB driver using the nonblocking ngx_lua cosocket API.
It supports MongoDB 6.0, 7.0, 8.0 and 9.0 through `OP_MSG`, with CRUD,
SCRAM authentication, TLS, aggregation, replica-set reads, GridFS, sessions
and transactions. Based on [daurnimator's Mongol](https://github.com/daurnimator/mongol).

**Release:** **1.0.0** consolidates all modernization phases into one major
release. Read the
[migration guide](#migration-to-100) before upgrading an older application.

## Table of contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Synopsis](#synopsis)
- [Migration to 1.0.0](#migration-to-100)
- [Queries and pagination](#queries-and-pagination)
- [Connections, login and pooling](#connections-login-and-pooling)
- [Connection strings and read preference](#connection-strings-and-read-preference)
- [Database methods](#database-methods)
- [Collection methods](#collection-methods)
- [Cursor methods](#cursor-methods)
- [BSON and ObjectId](#bson-and-objectid)
- [Sessions and transactions](#sessions-and-transactions)
- [Command monitoring](#command-monitoring)
- [GridFS](#gridfs)
- [Testing and packaging](#testing-and-packaging)
- [Limitations](#limitations)
- [License](#license)

## Requirements

Use OpenResty with LuaJIT and its bundled Lua libraries (`resty.random`,
`resty.sha1`, `resty.sha256`, `resty.md5`, `resty.string` and `cjson`). The
SCRAM implementation uses LuaJIT FFI with OpenResty's linked OpenSSL. No
additional C module is built. CI uses OpenResty **1.31.1.1** and a MongoDB
6.0/7.0/8.0/9.0 matrix.

Create connections and perform I/O in a phase that supports cosockets, such
as `content_by_lua_block` or an ngx_lua timer. Requiring the library and
creating an unconnected object with `mongol:new()` work in `init_by_lua`.
Keep connected objects local to the request or timer; do not share a socket
between concurrent requests.

## Installation

### LuaRocks

Install the [published package](https://luarocks.org/modules/laobei2012/lua-resty-mongol)
with LuaRocks configured for OpenResty's LuaJIT (Lua 5.1):

```sh
luarocks install lua-resty-mongol 1.0.0-1
```

LuaRocks installs into its configured tree. If that tree is separate from
OpenResty, add both Lua file and directory-module lookup patterns to
`lua_package_path`. For example, for a tree rooted at `/usr/local`:

```nginx
lua_package_path "/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua;;";
```

LuaRocks manages installation only; OpenResty remains the required runtime.
The rockspec pins the `v1.0.0` source tag.

### From source

From a checkout (use the `v1.0.0` tag for the released source):

```sh
make install PREFIX=/usr/local/openresty
```

This installs all modules under `lualib/resty/mongol`. Include both Lua file
and directory-module lookup patterns in `nginx.conf`:

```nginx
lua_package_path "/usr/local/openresty/lualib/?.lua;/usr/local/openresty/lualib/?/init.lua;;";
```

To build this checkout locally with LuaRocks instead:

```sh
luarocks make lua-resty-mongol-1.0.0-1.rockspec
```

OPM metadata supports local `opm build`. The OPM registry upload is still
pending server processing; use LuaRocks or source installation for now.

## Synopsis

Inside `content_by_lua_block`, against a local server without authentication:

```lua
local mongol = require "resty.mongol"
local bson = require "resty.mongol.bson"
local cjson = require "cjson"

local conn = mongol:new()
conn:set_timeout(5000)
assert(conn:connect("127.0.0.1", 27017))
local db = conn:new_db_handle("example")
local col = db:get_col("inventory")
assert(col:insert({{item = "pen", qty = 120, price = 2.5}}, nil, true))

local doc, err = col:find_one({item = "pen"}, {_id = 0})
if err then
    conn:close()
    error(err)
end
ngx.say(cjson.encode(bson.to_json_safe(doc)))
assert(conn:set_keepalive(10000, 20))
```

`require "resty.mongol"` returns a module table; it does not connect.
`find_one` returns **one document**, `nil` for no match, or `nil, err`.

## Migration to 1.0.0

The public method names remain. The following data and return-value changes
need attention; [the changelog](Changes.md) records their reasons.

- **Numbers:** whole numbers in int32 range are encoded as int32, larger
  whole numbers in int64 range as int64, and other numbers as doubles.
  Negative zero remains a double. Before, every number was a double.
  `mongol.int32(n)`, `mongol.int64(n)` and `mongol.double(n)` force a type.
  On read, integers outside the exact Lua-number range (magnitude above
  2^53) remain LuaJIT `int64_t` cdata. Construct large exact integers from
  cdata, for example `mongol.int64(9007199254740993LL)`; a Lua number literal
  has already lost precision at that value.
- **Arrays:** Lua indexes are 1-based on both write and read. Old writes of
  `{a, b}` produced `[null, a, b]`; those stored arrays now read back with the
  leading null intact. Audit and migrate that stored data before upgrading.
  Dense tables with keys 1 through n are arrays; `{}` is a document. Use
  `bson.empty_array` for an empty array. Decoded arrays have `bson.array_mt`
  so empty arrays survive another write. Other tables encode as documents
  with stringified numeric keys, replacing the old `_keys`/`_vals` encoding.
- **Null:** BSON null reads as `bson.null`, not `nil`. A key or array slot
  stays present. `if doc.x then` is true for null; test
  `doc.x ~= nil and doc.x ~= bson.null` for a non-null value.
- **Wrappers:** dates read as signed `{v = milliseconds}`, binary as
  `{v = bytes, st = subtype_byte}`, and timestamps as `{t = seconds,
  i = increment}`. Use the constructors below, rather than plain tables,
  when writing these BSON types.
- **Commands:** `db:cmd` returns the document on success, or
  `nil, errmsg, reply` on a server error. It no longer returns the legacy
  fourth `OP_REPLY` flags value. Use `bson.ordered` for multi-key commands.
- **Errors:** socket, protocol and server errors return `nil, err` (see the
  low-level query exception below). Bad caller types raise `bad argument`.
  Update/delete selectors must be tables, preventing accidental full-table
  changes through a nil selector. Invalid collection options also raise
  `bad argument` before I/O.
- **Cursors:** `find` traverses all batches. Its batch size is not a total
  limit. Call `cursor:close()` when stopping early; there is no cosocket
  finalizer. `skip` and `limit` must precede the first fetch. `sort` before
  fetching runs on the server; after fetching it sorts only the remaining
  current batch on the client.
- **Writes:** `safe = nil`, `false` or `0` requests `w = 0` and returns `-1`.
  An acknowledged insert returns `0`; update/delete return the affected
  count. Inside a transaction writes are always acknowledged.
- **Authentication:** MONGODB-CR is removed. `auth` negotiates SCRAM-SHA-256
  or SCRAM-SHA-1; SHA-256 currently requires an ASCII password. A pooled
  socket retains its login: separate pools by user and authentication
  database, and skip login on a reused socket.
- **GridFS:** `read` returns bytes, `get` returns `true`, and writes grow
  the handle's `file_size`. New files made with `new` have no `md5`; `write`
  removes it. `new`/`insert` no longer add `length`, `uploadDate` or `md5`
  to your metadata table (they still set `_id`, `filename`, `chunkSize`).

## Queries and pagination

Lua string keys express MongoDB operators and dotted paths directly.
The `$or` value is a 1-based Lua array, not a table starting at index zero:

```lua
local cur = assert(col:find({
    ["$or"] = {
        {qty = {["$gt"] = 100}},
        {price = {["$lt"] = 9.95}},
    },
    ["supplier.address.city"] = "Vancouver",
}, {_id = 0, item = 1, qty = 1}, 100))

while true do
    local i, doc = cur:next()
    if not i then
        if doc then error(doc) end  -- second value is an error at failure
        break
    end
    ngx.say(require("cjson").encode(doc))
end
assert(cur:close())
```

For a page, set `skip` and `limit` **before** `sort`, because `sort` fetches
the first batch immediately. Use a stable unique key for deterministic pages:

```lua
local page, page_size = 3, 20
local cur = assert(col:find({}, nil, 10))
assert(cur:skip((page - 1) * page_size))
assert(cur:limit(page_size))
assert(cur:sort({_id = 1}))
for _, doc in cur:pairs() do
    ngx.say(doc._id:tostring())
end
assert(cur:close())
```

`pairs()` reads the current batch and fetches another when needed; it does
not query the server for every document. Use `next()` when you need to
handle fetch errors explicitly: a generic `for` loop stops on a nil index.
Large skips can be expensive; applications can instead use a range query
such as `{_id = {["$gt"] = last_id}}` with the same sort.

Aggregation also returns a cursor:

```lua
local cur = assert(col:aggregate({
    {["$match"] = {qty = {["$gt"] = 0}}},
    {["$group"] = {_id = "$item", total = {["$sum"] = "$qty"}}},
}, {batch_size = 50}))
for _, doc in cur:pairs() do
    ngx.say(doc._id, ": ", doc.total)
end
assert(cur:close())
```

## Connections, login and pooling

`conn = mongol:new()` creates an unconnected object. The connection methods:

| Call | Result and behavior |
| --- | --- |
| `conn:connect(host, port, opts)` | Success value, or `nil, err`; with TLS the second success value is the TLS session. Defaults on a new object: `localhost`, `27017`. |
| `conn:set_timeout(msec)` | Sets connect/read/write timeouts in milliseconds; returns `true` before a socket exists, otherwise the cosocket result. |
| `conn:set_keepalive(msec, pool_size)` | Returns `1` or `nil, err`; pools the socket and any `read_conn`. Rejects broken sockets and any open transaction. |
| `conn:get_reused_times()` | Reuse count, or `nil, err`. Zero means a new socket. |
| `conn:close()` | Closes this socket and `read_conn`; cosocket success value or `nil, err`. |
| `conn:ismaster()` | `isWritablePrimary, hosts`, or `nil, err`; sends `hello`. |
| `conn:getprimary(already_checked)` | A connection to the primary, possibly this connection itself, or `nil, err`. Optional discovery bookkeeping table. |
| `conn:databases()` | Array of database descriptions (`name`, `empty`, `sizeOnDisk`), or `nil, err`. |
| `conn:shutdown()` | `true` if shutdown succeeds or the server closes the socket; otherwise `nil, err`. |
| `conn:new_db_handle(name)` | Database handle. No network request. |
| `conn:start_session()` | Logical session, or `nil, err` if random-byte generation fails. |

`opts` accepts `pool`, `pool_size`, `backlog`, `ssl`, `ssl_verify`,
`ssl_server_name`, `ssl_reused_session`. TLS verification defaults to true;
the server name defaults to the host. Configure
`lua_ssl_trusted_certificate /path/to/ca.pem;` in `nginx.conf`. For DNS
hosts configure `resolver` with your deployment's DNS server. A plain
connection with no explicit host retains the historic `localhost` default;
use an IP address or configure DNS resolution.

With no custom pool, TLS settings form part of the pool identity. With a
custom `pool`, assign one name to exactly one authentication identity and
TLS configuration: a reused TLS socket skips the handshake and must not be
reused with different verification rules.

Login belongs to the socket, not the handle. A manual login/pool pattern
(`user` and `password` come from application configuration):

```lua
local conn = mongol:new()
conn:set_timeout(5000)
assert(conn:connect(host, port, {pool = "inventory:admin:app_user"}))
local auth_db = conn:new_db_handle("admin")
if conn:get_reused_times() == 0 then
    local ok, err = auth_db:auth(user, password)
    if not ok then
        conn:close()
        error(err)
    end
end
local db = conn:new_db_handle("inventory")
-- use db here, then close every unfinished cursor
assert(conn:set_keepalive(10000, 20))
```

`conn:connect()` with no arguments reuses the last successful host, port
and options. A URI connection also restores its login on a fresh socket
and reconnects its read connection. Failed URI reconnect login closes the
socket so it cannot enter a pool. An explicit `connect(host, port, opts)`
clears URI login, read-connection and read-preference state; log in manually
if the new endpoint requires it. `getprimary` carries TLS settings into
discovery, but callers must authenticate a newly returned socket themselves.

## Connection strings and read preference

```lua
local conn, err = mongol.connect_uri(
    "mongodb://host1:27017,host2:27017/inventory?readPreference=secondaryPreferred")
```

This returns the primary connection, or `nil, err`. For authentication use
`mongodb://USER:PASSWORD@host1:27017/inventory?authSource=admin`; substitute
percent-encoded configuration values (`@` becomes `%40`, `:` becomes `%3A`).
URI connections manage authentication and separate user pools automatically.

Supported options: `authSource` (defaults to the URI database, or `admin`),
`tls=true|false`, `replicaSet` (parsed but not validated against the server),
and `readPreference`. Unknown options are ignored; the last repeated value
wins. `tls=true` verifies the certificate against the host name and needs a
trusted CA; use DNS names, not IP literals, for that verification.

| Read preference | Behavior |
| --- | --- |
| `primary` (default) | All reads use the primary. |
| `primaryPreferred` | Reads use the primary; no primary still makes connection fail because writes require one. |
| `secondary` | Reads use a secondary through `conn.read_conn`; no secondary makes connection fail. |
| `secondaryPreferred` | Reads use a secondary when available, otherwise the primary. |

Writes and `db:cmd` always use the primary. `query`, `find`, `find_one`,
`count` and `aggregate` follow read preference. A session uses its own
primary connection; a transaction never reads from `read_conn`. A cursor
keeps its first server for `getMore` and `killCursors`. Secondary reads may
lag writes. Selection happens at connect time; there is no background
topology monitor or automatic operation retry after failover.

`require("resty.mongol.uri").parse(str)` returns
`{hosts = {{host = "h1", port = 27017}, ...}, db, user, password, options}`,
or `nil, err`. It percent-decodes the user, password and database.
`uri.parse_host(str)` parses `host:port` or `[ipv6]:port` into a host table.
`mongodb+srv://` and unix-domain-socket URIs are not supported.

## Database methods

| Call | Result |
| --- | --- |
| `db:cmd(command)` | Reply document, or `nil, errmsg, reply` for a server error; socket/protocol errors return `nil, err`. |
| `db:listcollections(num_each)` | Cursor over collection descriptions, or `nil, err`; optional batch size. `db:list` is an alias. |
| `db:dropDatabase()` | `1` or `nil, err`. |
| `db:add_user(username, password)` | `createUser` reply or `nil, err`; creates a user with no roles. Use an ordered command to assign roles. |
| `db:auth(username, password)` | `1` or `nil, err`; negotiates SCRAM-SHA-256, falling back to SCRAM-SHA-1 if listed. |
| `db:auth_scram_sha1(username, password)` | `1` or `nil, err`; explicitly uses SCRAM-SHA-1. |
| `db:get_col(name)` | Collection handle, or `nil, "collection needed"`. |
| `db:get_gridfs(prefix)` | GridFS bucket handle, or `nil, "fs name needed"`; e.g. `"fs"` for `fs.files`/`fs.chunks`. |

MongoDB requires the command name as the first BSON key. Lua `pairs` order
is not a command-order guarantee. One-key commands such as `{ping = 1}`
work directly; for multiple keys use `bson.ordered`:

```lua
local bson = require "resty.mongol.bson"
local reply, err = db:cmd(bson.ordered({
    {"create", "inventory"},
    {"capped", false},
}))
```

The driver appends `$db` and its other protocol fields without changing the
command table. The legacy `resty.mongol.misc.attachpairs_start` helper also
remains available; the library never overrides global `pairs`.
MongoDB normally creates an absent collection on first insert; use `create`
when you need explicit options.

## Collection methods

`safe`, `continue_on_error`, `upsert`, `multiupdate` and `single_remove`
treat `nil`, `false` and `0` as false and every other value as true. `safe`
false means unacknowledged `writeConcern = {w = 0}`: no reply is read and
`-1` means sent, not confirmed success. Acknowledged writes return `nil, err`
for write errors or write-concern errors. Large inserts split into batches
within the server's document, message and batch limits.

| Call | Result and options |
| --- | --- |
| `col:insert(docs, continue_on_error, safe, opts)` | `0` for acknowledged success, `-1` for unacknowledged, or `nil, err`. `docs` is an array; continue-on-error sends unordered inserts. |
| `col:update(selector, update, upsert, multiupdate, safe, opts)` | For acknowledged success, matched count or `1` for an inserted upsert; `-1` for unacknowledged, or `nil, err`. Multi-update requires update operators. |
| `col:delete(selector, single_remove, safe, opts)` | Deleted count for acknowledged success, `-1` for unacknowledged, or `nil, err`. A true `single_remove` deletes at most one. |
| `col:count(query)` | Count or `nil, err`. Uses the count command; it is not session-aware and is not a transactional read. |
| `col:drop()` | `1` or `nil, err`. |
| `col:find_one(query, fields, opts)` | One document, `nil` for no match, or `nil, err`. |
| `col:find(query, fields, num_each_query, opts)` | Lazy cursor; default batch size 100, 0 uses server defaults, 1 returns `nil, err`. Traverse the cursor to get all matches. |
| `col:aggregate(pipeline, options)` | Cursor or `nil, err`. `options.batch_size` defaults to 100; non-negative integer, 0 delegates batch sizing. Supports `options.session`; other aggregation options are not forwarded. An empty pipeline is sent as an empty array. |
| `col:find_and_modify(options)` | One returned document, `nil` for no match, or `nil, err`. Requires `query` and `update` or `remove`; command options such as `new` and `upsert` are forwarded. It does not mutate the options table. |

Projection `fields` uses `{name = 1}` or `{name = 0}` according to MongoDB
projection rules. Optional `opts.session` attaches a session belonging to
this connection. `query` uses its existing fifth options argument for that
session. `find_and_modify`, `count` and `drop` have no session argument.

Low-level cursor calls retain their public 8-byte cursor ID strings:

- `id, results, flags, err = col:query(query, fields, numberToSkip,
  numberToReturn, options)`. Skip defaults to 0. A nil return count means
  one result in a single batch; negative counts mean a single batch of the
  absolute size. A positive count is a batch size, not a total limit;
  1 also uses a single batch. Options include `sort`, `limit`,
  `TailableCursor`, `AwaitData`, `NoCursorTimeout`, `Partial`, `session`.
- `id, results, flags, err = col:getmore(cursorID, numberToReturn, offset_i,
  opts)`. A positive return count sets the batch size; otherwise the server
  chooses. `offset_i` is retained for compatibility; each returned batch is
  indexed from 1. Results are not padded with empty leading positions.
- `col:kill_cursors(cursorIDs, opts)` returns `true` or `nil, err`.

On server query errors the first three values retain their shape, `err` is
the fourth value, and `flags.CursorNotFound` (code 43) or `flags.QueryFailure`
is true. Socket/protocol errors return `nil, err`. An all-zero 8-byte ID
means there are no more server batches. Use a high-level cursor unless you
need to manage batches yourself.

## Cursor methods

| Call | Result |
| --- | --- |
| `cursor:next()` | `index, document`; index starts at 1. End: `nil`. Failure: `nil, err`. |
| `cursor:pairs()` | Iterator for a generic `for` loop. Use `next` for explicit error handling. |
| `cursor:skip(n)` | `true`, or `nil, "cursor already started"`; non-negative integer, before first fetch. |
| `cursor:limit(n)` | `true`, or `nil, "cursor already started"`; 0 means no total limit. |
| `cursor:sort(field, size)` | Remaining batch array or `nil, err`. Before fetching: sends the sort to the server and fetches the first batch. After fetching: sorts the unconsumed current batch locally. `size` defaults to 10000 and must exceed 1; it is retained for compatibility, not a total result limit. |
| `cursor:close()` | `true` or `nil, err`; discards local results and kills the server cursor. |

Use a single-field sort map such as `{age = -1}`, not `{{age = -1}}`.
For deterministic multi-key server order use an ordered sort document via
low-level `query` options. A returned sort batch remains owned by the
cursor; do not separately iterate it and then expect `next()` to skip it.
Always close an unfinished cursor before returning its connection to the
pool, including after reaching a client-side limit. There is no `__gc`
network cleanup; otherwise the server removes idle cursors on its timeout.

## BSON and ObjectId

```lua
local bson = require "resty.mongol.bson"
local object_id = require "resty.mongol.object_id"
local id = assert(object_id.new_from_hex("507f1f77bcf86cd799439011"))
local doc = {owner = id, created = bson.get_utc_date(-1), tags = bson.empty_array}
local json = require("cjson").encode(bson.to_json_safe(doc))
```

| Helper/value | Meaning |
| --- | --- |
| `bson.int32(n)`, `bson.int64(n)`, `bson.double(n)` | Force a numeric BSON type; also exported by `mongol`. |
| `bson.null`, `bson.empty_array` | Explicit BSON null and empty array. |
| `bson.ordered({{key, value}, ...})` | Ordered document, useful for commands and multi-key index definitions. |
| `bson.get_utc_date(ms)` | Signed date wrapper; milliseconds since Unix epoch. |
| `bson.get_bin_data(bytes, subtype)` | Binary wrapper; numeric subtype defaults to 0; decoded `.st` is a one-byte string. |
| `bson.timestamp(t, i)` | BSON timestamp, distinct from a date. |
| `bson.decimal128(str)` | Decimal128 wrapper or `nil, err`; `tostring(value)` gives its decimal representation. |
| `bson.regex(pattern, options)` | Regex wrapper with sorted options. |
| `bson.minkey()`, `bson.maxkey()` | MinKey and MaxKey wrappers. |
| `bson.to_bson(doc)` | Encoded bytes or `nil, err`; invalid keys, including embedded NUL, are rejected. |
| `bson.decode(bytes)` | Decodes BSON; malformed input can raise. Network reply parsing catches decoder errors. |
| `bson.from_bson(get)` | Legacy decoder accepting a byte-source function. |
| `bson.to_json_safe(doc)` | Copy suitable for `cjson.encode`; does not alter the input. |

The JSON-safe copy maps ObjectId to hex, dates to ISO 8601 with
milliseconds, binary to base64, null to `cjson.null`, and Decimal128 or
large int64 to decimal strings. Empty arrays stay arrays. Timestamp and
regex wrappers become ordinary tables; MinKey/MaxKey and non-finite doubles
become strings. This conversion is for JSON output, not a lossless BSON
storage format.

`object_id.new()` generates an ID, `object_id.new(bytes)` accepts exactly
12 raw bytes, and `object_id.new_from_hex(hex)` accepts 24 hex characters.
They return an ObjectId or `nil, err`. `id:tostring()`/`tostring(id)` gives
hex; `id:get_ts()` gives epoch seconds, and `id:get_inc()` gives the counter.
`get_hostname()` and `get_pid()` retain historic names/byte ranges; the
current ObjectId layout uses five process-random bytes, so those values
are not the actual hostname or PID.

## Sessions and transactions

`session = conn:start_session()` creates a logical session with a random
UUID `lsid`. Pass `{session = session}` as the last argument of `insert`,
`update`, `delete`, `find`, `find_one`, `getmore` and `kill_cursors`, or as
`query`'s fifth argument and `aggregate`'s options. A session from another
connection raises `bad argument`.

```lua
local session = assert(conn:start_session())
assert(session:start_transaction())
assert(col:insert({{a = 1}}, nil, nil, {session = session}))
local doc = assert(col:find_one({a = 1}, nil, {session = session}))
local ok, err, reply = session:commit_transaction()
-- Check ok; see recovery below before returning the connection to its pool.
```

Transactions require a replica set. All their operations use the primary,
ignore `read_conn`, send no operation write concern, and acknowledge writes
regardless of `safe`. Outside a transaction, an unacknowledged write with a
session returns `nil, "unacknowledged write with a session"` without sending.
Cursors retain the session through `getMore` and `killCursors`. `count` is
not a transactional read and can include uncommitted documents; use an
aggregation with the session instead.

`start_transaction()` returns `true` or `nil, err`. An empty transaction's
commit or abort completes locally. `commit_transaction()` and
`abort_transaction()` return `true` or `nil, err, reply`; a commit reply
with `writeConcernError` is a failure. A failed commit retains its
transaction number. A repeated commit sends `w = "majority", wtimeout =
10000`. An abort ends local transaction state even on failure. A failed
first send preserves `startTransaction` for a retry after reconnect.

For an unknown commit result, inspect `reply.errorLabels`. The driver adds
`UnknownTransactionCommitResult` for a socket failure/timeout, error 50,
`RetryableWriteError`, or a write concern error other than 79/100. Preserve
that session and retry the commit; do not start another transaction to
resolve an unknown commit. For socket failure recovery on a manually
connected and authenticated connection:

```lua
-- conn is still the same object; its old socket failed.
assert(conn:connect()) -- same host, port and TLS options
if conn:get_reused_times() == 0 then
    assert(conn:new_db_handle(auth_source):auth(user, password))
end
local ok, err, reply = session:commit_transaction() -- same txnNumber
```

A URI connection restores its stored login automatically on reconnect.
Applications choose retry deadlines; the driver does not automatically
retry commit. For a known failure that you decide not to retry, call
`session:abort_transaction()` before reusing the session.

`conn:set_keepalive()` returns `nil, "transaction in progress"` until
**every** session's open transaction on it has finished. The driver does
not send `endSessions`. Unused server sessions expire according to
`logicalSessionTimeoutMinutes` in `hello`; explicitly finish transactions
with commit or abort before pooling their connection.

## Command monitoring

`mongol.set_monitor(m)` accepts a table of optional `started`, `succeeded`
and `failed` functions, or nil to disable monitoring, and returns `true`.
The monitor is worker-wide. Events contain `command_name`, `db`,
`request_id`, `host`, `port`; `started` adds a copied `command`, `succeeded`
adds copied `reply` and `duration_ms`, and `failed` adds `error` and
`duration_ms`. Events include driver-added fields such as `$readPreference`
and session fields. A hook cannot mutate the caller's command or reply.

Login commands (`authenticate`, `saslStart`, `saslContinue`, `getnonce`),
`createUser`, `updateUser`, and hello/isMaster variants containing
`speculativeAuthenticate` are redacted: commands/replies are empty and
`failed.error` is `"redacted"`. Sensitivity is captured before I/O. Hook
errors are logged and do not change the command result. Hooks run inline;
keep them short and avoid network I/O.

For [nginx-lua-prometheus](https://github.com/knyar/nginx-lua-prometheus),
with `prometheus` already initialized in `init_worker_by_lua_block`:

```lua
local commands = prometheus:counter("mongo_commands_total", "Commands", {"command", "result"})
local latency = prometheus:histogram("mongo_command_seconds", "Command time", {"command"})
require("resty.mongol").set_monitor({
    succeeded = function(ev)
        commands:inc(1, {ev.command_name, "ok"})
        latency:observe(ev.duration_ms / 1000, {ev.command_name})
        -- Inspect ev.reply.writeErrors / writeConcernError for write failures.
    end,
    failed = function(ev)
        commands:inc(1, {ev.command_name, "error"})
        latency:observe(ev.duration_ms / 1000, {ev.command_name})
    end,
})
```

A succeeded command may contain write errors. For unacknowledged writes,
`succeeded` only confirms that the message was sent. Without a monitor,
commands perform one monitor-presence check and build no events.

## GridFS

`fs = db:get_gridfs("fs")` selects `fs.files` and `fs.chunks`.

| Call | Result and behavior |
| --- | --- |
| `fs:find_one(fields)` | GridFS file handle, `nil` for no match, or `nil, err`. |
| `fs:remove(fields, continue_on_err, safe)` | Number of file records processed, or `nil, err`. The legacy second argument is passed as `single_remove` to each delete; use nil/false/0 to remove all chunks of each matching file. |
| `fs:get(fh, fields)` | Writes the first matching file to `fh`, returns `true` or `nil, err`. It buffers the whole file in memory. |
| `fs:insert(fh, meta, safe)` | Reads chunks from `fh:read(n)`; returns `0` for acknowledged insertion or `-1` for unacknowledged, or `nil, err`. It computes an MD5 digest while importing. |
| `fs:new(meta)` | Creates an empty stored file and returns a file handle, or `nil, err`. |
| `file:read(size, offset)` | Byte string or `nil, err`, not a byte count. Offset starts at 0; size defaults to the rest and is clipped at EOF. Empty files return `""`. |
| `file:write(buf, offset, size)` | Bytes written or `nil, err`. Offset is required and must lie from 0 through the current file size. Size defaults to `#buf`; it cannot exceed that length. Preserves untouched bytes and grows the file. |
| `file:update_md5()` | `true` or `false, err`; computes MD5 client-side over exactly the file's chunks. |

Metadata can include `_id`, `filename`, `chunkSize`, `contentType`, `aliases`,
`metadata` and application fields. Default chunk size is 256 KiB; it must
be a positive int32. `_id` defaults to an ObjectId and `filename` to its hex
string. `new` and `insert` still set these defaults in your `meta` table,
but do not add `length`, `uploadDate` or `md5` to it.

Chunks use int32 `n` and binary subtype 0; file metadata uses int32
`chunkSize` and int64 `length`. The bucket creates the unique
`{files_id: 1, n: 1}` chunks index. `read` and `update_md5` reject missing,
short or non-binary chunks. `write` validates existing chunks' binary type
and subtype, without checking their stored length. New chunks from `write`
are batched to fit server limits; existing chunks are updated.

`new` makes no `md5`; `write` removes it and never recomputes it. Call
`update_md5` explicitly if needed. MD5 is deprecated by the GridFS spec.
Stored length only grows. Concurrent writers to the same bytes are last
writer wins; use one writer when ordering matters.

## Testing and packaging

Run each suite separately against the appropriate server:

```sh
make test          # standalone, no authentication; downloads the BSON corpus
make test-auth     # authenticated server
make test-tls      # TLS server with the test certificates
make test-replset  # three-member replica set
make lint          # luacheck
```

Tests use Test::Nginx. Configure `TEST_NGINX_MONGO_HOST`,
`TEST_NGINX_MONGO_PORT`, `TEST_NGINX_MONGO_USER`, `TEST_NGINX_MONGO_PASS`.
Replica-set tests also use `TEST_NGINX_MONGO_SECONDARY_HOST` and
`TEST_NGINX_MONGO_SECONDARY_PORT`; TLS tests use `TEST_NGINX_MONGO_CA` and
`TEST_NGINX_MONGO_OTHER_CA`. See `.github/workflows/test.yml` for setup.
CI also runs OpenResty's `lj-releng` over every module. The BSON corpus is
not redistributed because its license differs from this library's.

Packaging checks, without publishing:

```sh
luarocks lint lua-resty-mongol-1.0.0-1.rockspec
opm build
```

The builtin rockspec lists every module explicitly. OPM reads `1.0.0` from
`lib/resty/mongol/init.lua`. Building a package locally does not publish it.
[OPM metadata](https://opm.openresty.org/docs#file-distini)
and the [LuaRocks rockspec format](https://github.com/luarocks/luarocks/blob/main/docs/rockspec_format.md)
describe the packaging fields.

## Limitations

- MongoDB 5.0 and earlier, wire compression, SRV discovery, background
  topology monitoring and client-side field-level encryption are outside
  this modernization's scope.
- SCRAM-SHA-256 passwords must be ASCII until full SASLprep is implemented.
- Server selection is synchronous at connection time. Reconnect and retry
  policy belongs to the application; no automatic write/transaction retry.
- GridFS does not provide conflict detection between concurrent writers.
- Existing method names, including mixed naming conventions, stay for API
  compatibility. Collection names cannot contain NUL; database names cannot
  contain a dot or NUL.

## License

MIT/X11. The notice is included here as well as in `LICENSE` so OPM's
README-only documentation packaging retains it:

```text
Copyright (c) 2010-2012 daurnimator (mongol)
Copyright (c) 2012-2019 bigplum and the lua-resty-mongol contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```
