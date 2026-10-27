OPENRESTY_PREFIX ?= /usr/local/openresty

PREFIX ?= /usr/local/openresty
LUA_INCLUDE_DIR ?= $(PREFIX)/include
LUA_LIB_DIR ?= $(PREFIX)/lualib
INSTALL ?= install

TEST_PATH = PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH

.PHONY: all test test-auth test-replset test-tls install lint

all: ;

install: all
	$(INSTALL) -d $(DESTDIR)$(LUA_LIB_DIR)/resty/mongol
	$(INSTALL) -m 644 lib/resty/mongol/*.lua $(DESTDIR)$(LUA_LIB_DIR)/resty/mongol

test:
	$(TEST_PATH) prove -I t/lib t/*.t

test-auth:
	$(TEST_PATH) prove -I t/lib t/auth

test-replset:
	$(TEST_PATH) prove -I t/lib t/replset

test-tls:
	$(TEST_PATH) prove -I t/lib t/tls

lint:
	luacheck -q lib
