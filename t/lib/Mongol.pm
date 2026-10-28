package Mongol;

use strict;
use warnings;
use Cwd qw(cwd);
use Exporter 'import';

our @EXPORT = qw($HttpConfig op_msg ok_doc);

$ENV{TEST_NGINX_MONGO_HOST} ||= '127.0.0.1';
$ENV{TEST_NGINX_MONGO_PORT} ||= 27017;
$ENV{TEST_NGINX_MONGO_USER} ||= 'admin';
$ENV{TEST_NGINX_MONGO_PASS} ||= 'admin';
# a secondary of the replica set, for t/replset
$ENV{TEST_NGINX_MONGO_SECONDARY_HOST} ||= '127.0.0.1';
$ENV{TEST_NGINX_MONGO_SECONDARY_PORT} ||= 27018;

my $pwd = cwd();
$ENV{TEST_NGINX_ROOT} ||= $pwd;
$ENV{TEST_NGINX_MONGO_CA} ||= "$pwd/t/tls/certs/ca.pem";
$ENV{TEST_NGINX_MONGO_OTHER_CA} ||= "$pwd/t/tls/certs/other-ca.pem";

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;$pwd/lib/?/init.lua;$pwd/t/lib/?.lua;;";
};

# {ok: 1.0} as BSON
sub ok_doc {
    return pack("V", 17) . "\x01ok\x00" . pack("d<", 1) . "\x00";
}

# an OP_MSG reply: flagBits, then the raw section bytes, then extra bytes
sub op_msg {
    my ($flags, $sections, $extra) = @_;
    $extra //= '';
    my $body = pack("V", $flags) . $sections . $extra;
    return pack("V V V V", 16 + length($body), 1, 0, 2013) . $body;
}

1;
