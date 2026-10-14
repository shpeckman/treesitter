# Makefile
CC     ?= cc
AR     ?= ar
CFLAGS ?= -O2 -fPIC -std=gnu11

DEPS  = vendor/deps
BUILD = vendor/build
TS    = $(DEPS)/tree-sitter-lib

COMPILE_C = $(CC) $(CFLAGS)

GRAMMAR_OBJS = $(BUILD)/json_parser.o \
	$(BUILD)/crystal_parser.o $(BUILD)/crystal_scanner.o $(BUILD)/crystal_unicode.o \
	$(BUILD)/python_parser.o $(BUILD)/python_scanner.o \
	$(BUILD)/c_parser.o \
	$(BUILD)/bash_parser.o $(BUILD)/bash_scanner.o

.PHONY: all native spec clean

all: native

native: $(BUILD)/libtree-sitter.a $(BUILD)/libgrammars.a

spec: native
	crystal spec

$(DEPS): vendor/tree-sitter-deps.tar.gz
	tar xzf $< -C vendor
	touch $@

$(BUILD)/libtree-sitter.a: $(DEPS)
	mkdir -p $(BUILD)
	$(COMPILE_C) -I$(TS)/include -I$(TS)/src -c $(TS)/src/lib.c -o $(BUILD)/ts_lib.o
	$(AR) rcs $@ $(BUILD)/ts_lib.o

$(BUILD)/libgrammars.a: $(GRAMMAR_OBJS)
	rm -f $@
	$(AR) rcs $@ $(GRAMMAR_OBJS)

$(BUILD)/%_parser.o: $(DEPS)
	mkdir -p $(BUILD)
	$(COMPILE_C) -I$(DEPS)/$* -c $(DEPS)/$*/parser.c -o $@

$(BUILD)/%_scanner.o: $(DEPS)
	mkdir -p $(BUILD)
	$(COMPILE_C) -I$(DEPS)/$* -c $(DEPS)/$*/scanner.c -o $@

$(BUILD)/crystal_unicode.o: $(DEPS)
	mkdir -p $(BUILD)
	$(COMPILE_C) -I$(DEPS)/crystal -c $(DEPS)/crystal/unicode.c -o $@

clean:
	rm -rf $(BUILD) $(DEPS)
