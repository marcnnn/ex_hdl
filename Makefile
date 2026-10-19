# Builds the SIMD NIF (c_src/simd) for ExHdl.SIMD. Driven by elixir_make,
# which sets MIX_APP_PATH, ERTS_INCLUDE_DIR and (via mix.exs) FINE_INCLUDE_DIR.
#
# Google Highway is fetched once (pinned version and SHA-256) and the few
# library sources needed for runtime dispatch are compiled into the NIF, so
# no system package is required.

HWY_VERSION := 1.4.0
HWY_SHA256  := e72241ac9524bb653ae52ced768b508045d4438726a303f10181a38f764a453c
HWY_URL     := https://github.com/google/highway/archive/refs/tags/$(HWY_VERSION).tar.gz

MIX_APP_PATH ?= _build/dev/lib/ex_hdl
BUILD_DIR    := $(abspath $(MIX_APP_PATH)/../..)/ex_hdl_native
HWY_DIR      := $(BUILD_DIR)/highway-$(HWY_VERSION)
OBJ_DIR      := $(BUILD_DIR)/obj
PRIV_DIR     := $(MIX_APP_PATH)/priv/native
NIF          := $(PRIV_DIR)/libexhdl_simd.so

HWY_SRCS := abort aligned_allocator per_target print targets timer
HWY_OBJS := $(addprefix $(OBJ_DIR)/hwy_,$(addsuffix .o,$(HWY_SRCS)))
OBJS     := $(OBJ_DIR)/kernels.o $(OBJ_DIR)/nif.o $(HWY_OBJS)

CXX      ?= g++
CXXFLAGS ?= -O3
CXXFLAGS += -std=c++17 -fPIC -fvisibility=hidden -Wall -Wextra -Wno-unused-parameter

# 32-bit ARM (e.g. Zynq-7000 Cortex-A9, NEON + VFPv3). Highway disables NEON
# on ARMv7 without VFPv4 unless overridden; the kernels are integer-only, so
# the override is safe (verified bit-exact under qemu -cpu cortex-a9).
# Do not use -mfpu=neon-vfpv4: real Cortex-A9 cores lack VFPv4.
ifneq ($(filter arm%,$(firstword $(subst -, ,$(shell $(CXX) -dumpmachine)))),)
ifeq ($(filter aarch64%,$(shell $(CXX) -dumpmachine)),)
CXXFLAGS += -march=armv7-a -mfpu=neon -mfloat-abi=hard -DHWY_BROKEN_ARM7_WITHOUT_VFP4=0 -Wno-psabi
endif
endif
CPPFLAGS += -I$(HWY_DIR) -I$(ERTS_INCLUDE_DIR) -I$(FINE_INCLUDE_DIR) -Ic_src/simd
LDFLAGS  += -shared -ldl

all: $(NIF)

$(NIF): $(OBJS)
	@mkdir -p $(PRIV_DIR)
	$(CXX) $(CXXFLAGS) -o $@ $^ $(LDFLAGS)

$(OBJ_DIR)/kernels.o: c_src/simd/kernels.cc c_src/simd/kernels.h $(HWY_DIR)/.ok
	@mkdir -p $(OBJ_DIR)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -c $< -o $@

$(OBJ_DIR)/nif.o: c_src/simd/nif.cc c_src/simd/kernels.h $(HWY_DIR)/.ok
	@mkdir -p $(OBJ_DIR)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -c $< -o $@

$(OBJ_DIR)/hwy_%.o: $(HWY_DIR)/.ok
	@mkdir -p $(OBJ_DIR)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -c $(HWY_DIR)/hwy/$*.cc -o $@

$(HWY_DIR)/.ok:
	@mkdir -p $(BUILD_DIR)
	curl -sSfL -o $(BUILD_DIR)/highway.tar.gz $(HWY_URL)
	echo "$(HWY_SHA256)  $(BUILD_DIR)/highway.tar.gz" | sha256sum -c -
	tar xzf $(BUILD_DIR)/highway.tar.gz -C $(BUILD_DIR)
	touch $@

clean:
	rm -rf $(OBJ_DIR) $(NIF)

.PHONY: all clean
