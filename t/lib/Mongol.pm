package Mongol;

use strict;
use warnings;
use Cwd qw(cwd);
use Exporter 'import';

our @EXPORT = qw($HttpConfig);

$ENV{TEST_NGINX_MONGO_HOST} ||= '127.0.0.1';
$ENV{TEST_NGINX_MONGO_PORT} ||= 27017;
$ENV{TEST_NGINX_MONGO_USER} ||= 'admin';
$ENV{TEST_NGINX_MONGO_PASS} ||= 'admin';

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;$pwd/lib/?/init.lua;$pwd/t/lib/?.lua;;";
};

1;
