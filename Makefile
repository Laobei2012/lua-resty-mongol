OPENRESTY_PREFIX ?= /usr/local/openresty

PREFIX ?= /usr/local/openresty
LUA_INCLUDE_DIR ?= $(PREFIX)/include
LUA_LIB_DIR ?= $(PREFIX)/lualib
INSTALL ?= install

TEST_PATH = PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH

.PHONY: all spec-data test test-auth test-replset test-tls install lint

all: ;

install: all
	$(INSTALL) -d $(DESTDIR)$(LUA_LIB_DIR)/resty/mongol
	$(INSTALL) -m 644 lib/resty/mongol/*.lua $(DESTDIR)$(LUA_LIB_DIR)/resty/mongol

SPEC_SHA = 9ea18a92308ed437e16dd95e6ff9c496daa61ecd

# The BSON corpus is CC BY-NC-SA 3.0, so it is downloaded, not committed.
spec-data: t/spec/bson-corpus/.done

t/spec/bson-corpus/.done:
	mkdir -p t/spec/bson-corpus
	curl -sSfL https://codeload.github.com/mongodb/specifications/tar.gz/$(SPEC_SHA) \
		| tar xz -C t/spec/bson-corpus --strip-components=4 \
			specifications-$(SPEC_SHA)/source/bson-corpus/tests
	touch $@

test: spec-data
	$(TEST_PATH) prove -I t/lib t/*.t

test-auth:
	$(TEST_PATH) prove -I t/lib t/auth

test-replset:
	$(TEST_PATH) prove -I t/lib t/replset

test-tls:
	$(TEST_PATH) prove -I t/lib t/tls

lint:
	luacheck -q lib
