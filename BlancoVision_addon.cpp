/*
 * Copyright (c) 2026 blancodagoat
 * SPDX-License-Identifier: MIT
 * See LICENSE next to this file.
 */

// BlancoVision.addon: a ReShade 5+ add-on. Build: python tools/build_addon.py
//
// Everything is driven from uniforms in any effect file, through a custom < bv = "..." >
// annotation. Not ReShade own < source = "..." >: that marks a special uniform and draws no widget.
//
//   "enable"  bool, master switch
//   "dump"    bool, logs each (pixel shader hash, register) cbuffer size and first 256 floats to
//             ReShade.log; toggling off and on logs a fresh snapshot, so game states can be diffed
//   "patch"   rewrites 1 to 4 floats of a game cbuffer on the CPU side of every upload
//   "read"    fills 1 to 16 floats from a game cbuffer (a float4x4 takes a whole matrix, in buffer
//             order, so a column major game matrix arrives transposed: mul(v, M))
//   "inject"  packs the uniform into a cbuffer this add-on owns and binds for the [Inject] group,
//             so a replacement shader can take parameters the game has no float for
//
// Companion annotations: bv_group (hash group from the ini, "" = every pixel shader), bv_slot
// (register, b5 = 5, pixel stage), bv_offset (float index, packoffset c67.y = 67 * 4 + 1 = 269),
// bv_op ("set" | "mul" | "add", patch only), bv_switch (name of a bool uniform gating the rule),
// bv_size (only buffers of exactly this byte size, guards a register two cbuffers share).
//
// bv_when_offset plus bv_when gate a patch on the buffer's own contents: the rule applies only
// when the float at bv_when_offset falls inside the float2 uniform bv_when names. The same
// cbuffer is uploaded once per light, so this is how one slider reaches street lights and not
// head lights: gate on the light radius and set the range.
//
// Shaders are also replaced by hash: the DXBC is CRC32-hashed at pipeline creation and swapped for
// <ReShade base path>\BlancoVision\0x<hash>.cso when that file exists.
//
// BlancoVision.addon.ini next to ReShade.ini: [Groups] name=0x...,0x... hash lists (a group present
// but empty matches nothing, which switches its rules off), [Replace] Enable, [Inject] Enable/Slot/
// Group, [HDR] FlipModel/Float/DumpComposite/UpgradeTargets. All of it is editable in the
// BlancoVision window in the ReShade overlay, which writes the file back.

#include <imgui.h>
#include <reshade.hpp>
#include <Windows.h>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

using namespace reshade::api;

// ---------------------------------------------------------------------------- crc32 (Gary S. Brown, as ReShade's examples)
static uint32_t crc32(const uint8_t *data, size_t size)
{
	static uint32_t table[256];
	static bool init = false;
	if (!init) { for (uint32_t i = 0; i < 256; i++) { uint32_t c = i; for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1; table[i] = c; } init = true; }
	uint32_t crc = 0xFFFFFFFFu;
	for (; size != 0; --size, ++data) crc = (crc >> 8) ^ table[(crc ^ *data) & 0xFF];
	return ~crc;
}

static const size_t DUMP_FLOATS = 256; // floats logged per cbuffer in dump mode; toggling bv_dump on again re-logs everything

static void logf(const char *fmt, ...)
{
	char buf[4096];
	va_list args; va_start(args, fmt); vsnprintf(buf, sizeof(buf), fmt, args); va_end(args);
	reshade::log::message(reshade::log::level::info, buf);
}

static std::string base_path()
{
	char path[MAX_PATH] = ""; size_t size = sizeof(path);
	reshade::get_reshade_base_path(path, &size);
	std::string s(path, size);
	if (!s.empty() && s.back() != '\\' && s.back() != '/') s += '\\';
	return s;
}

// ---------------------------------------------------------------------------- state
struct Rule
{
	effect_uniform_variable var = { 0 }, sw = { 0 }, when = { 0 };
	bool read = false, active = false, effective = false; // effective: active AND not a no-op
	std::string group;
	int slot = 0, offset = 0, count = 1, op = 0, size = 0; // op: 0 set, 1 mul, 2 add; size 0 = any
	int when_offset = -1;                                 // < 0 = ungated
	float when_range[2] = { 0, 0 };
	float value[4] = { 0, 0, 0, 0 }, readback[16] = { 0 };
	bool have_readback = false;
	// Diagnostics. A rule can be live and still touch nothing, because no shader binds a buffer of
	// that size at that register, or because the group excludes every shader that does. Without a
	// count there is no way to tell that apart from a setting the game ignores.
	char name[64] = "";
	uint64_t writes = 0;      // times this rule changed bytes on their way to the GPU
	bool seen_buffer = false; // a matching buffer was bound by a matching draw at least once
};
// One add-on owned cbuffer, filled from the effect once a frame.
struct Inject { effect_uniform_variable var = { 0 }; int offset = 0, count = 1; };
struct CmdState { uint32_t ps_hash = 0; uint64_t cb[16] = { 0 }; uint64_t cb_first[16] = { 0 }; uint64_t rtv = 0; };
struct Mapped { void *data; uint64_t offset; };
// One bit per rule, recorded per constant buffer. Two words because a panel that covers lights,
// shadows, AO, water and the postfx composite passes 64 rules on its own.
struct Mask
{
	uint64_t w[2] = { 0, 0 };
	void set(size_t i) { w[i >> 6] |= 1ull << (i & 63); }
	bool test(size_t i) const { return ((w[i >> 6] >> (i & 63)) & 1) != 0; }
	bool any() const { return (w[0] | w[1]) != 0; }
	void clear() { w[0] = w[1] = 0; }
	Mask operator&(const Mask &o) const { Mask r; r.w[0] = w[0] & o.w[0]; r.w[1] = w[1] & o.w[1]; return r; }
};
static const size_t MAX_RULES = 128;

static std::mutex s_mutex;
static std::vector<Rule> s_rules;                                   // at most MAX_RULES (one bit each in a target mask)
static std::unordered_map<std::string, std::unordered_set<uint32_t>> s_groups;
static std::unordered_map<uint64_t, uint32_t> s_pipeline_hash;      // pipeline handle -> pixel shader crc32
static std::unordered_map<command_list *, CmdState> s_cmd;
static std::unordered_map<uint64_t, Mask> s_targets;                // buffer handle -> rule bitmask
static std::unordered_map<uint64_t, uint64_t> s_base;               // buffer handle -> bound sub-range base, in floats
static std::unordered_map<uint64_t, Mapped> s_mapped;
struct Snapshot { uint64_t total = 0; std::vector<float> floats; };
static std::unordered_map<uint64_t, Snapshot> s_last;               // buffer handle -> last upload (dump mode)
static std::unordered_set<uint64_t> s_dumped;                       // (hash << 8 | slot) already logged, slot 0xFF = the render target line
static std::unordered_set<uint64_t> s_logged_copies;                // (source, dest) pairs already reported
static std::unordered_set<uint32_t> s_dumped_shaders;               // written once per hash per session
static std::unordered_set<uint64_t> s_backbuffers;                  // swap chain back buffer resources, so a dumped render target can name itself
static bool s_enabled = true, s_dump = false, s_replace = true;
// Ini only, never a uniform: the swap chain is created long before any effect runtime exists.
static bool s_hdr_flip = false, s_hdr_float = false;
// Dumps the exact bytecode the game creates, which is not always what the shader container holds.
static bool s_dump_shaders = false;
// The composite writes an 8 bit intermediate, so a float back buffer needs that target upgraded too.
static bool s_hdr_upgrade = false;
static uint32_t s_upgraded = 0;
static bool s_upgrade_pending = false;                             // set in create_resource, read by the init_resource right after it
static std::unordered_set<uint64_t> s_upgraded_res;                // resources this add-on changed the format of
static Mask s_effective_mask;                                       // rules currently changing a value
static effect_uniform_variable s_enable_var = { 0 }, s_dump_var = { 0 };
static const size_t INJECT_FLOATS = 64;                             // 256 bytes, 16 float4 registers
static std::vector<Inject> s_injects;
static bool s_inject_enable = true;
static int s_inject_slot = 13;
static std::string s_inject_group = "composite";                    // empty = off, so injection never binds on every draw
static device *s_inject_dev = nullptr;
static resource s_inject_buf = { 0 };
static float s_inject_data[INJECT_FLOATS] = { 0 };
static bool s_inject_upload = true;                                 // force the first upload after a reload
static thread_local std::vector<std::vector<uint8_t>> s_replaced_code;
static thread_local uint32_t s_original_hash = 0;                   // pixel shader hash before replacement
static unsigned s_replaced_count = 0;

static void load_ini()
{
	s_groups.clear();
	std::ifstream f(base_path() + "BlancoVision.addon.ini");
	std::string line, section;
	while (std::getline(f, line))
	{
		while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
		if (line.empty() || line[0] == ';') continue;
		if (line[0] == '[') { section = line.substr(1, line.find(']') - 1); continue; }
		const size_t eq = line.find('=');
		if (eq == std::string::npos) continue;
		const std::string key = line.substr(0, eq), val = line.substr(eq + 1);
		if (section == "Groups")
		{
			std::unordered_set<uint32_t> &g = s_groups[key];
			for (size_t p = 0; p < val.size();)
			{
				size_t q = val.find(',', p); if (q == std::string::npos) q = val.size();
				g.insert(static_cast<uint32_t>(std::strtoul(val.substr(p, q - p).c_str(), nullptr, 0)));
				p = q + 1;
			}
		}
		else if (section == "Replace" && key == "Enable") s_replace = val != "0";
		else if (section == "Inject" && key == "Enable") s_inject_enable = val != "0";
		else if (section == "Inject" && key == "Slot") s_inject_slot = static_cast<int>(std::strtol(val.c_str(), nullptr, 0));
		else if (section == "Inject" && key == "Group") s_inject_group = val;
		else if (section == "HDR" && key == "FlipModel") s_hdr_flip = val != "0";
		else if (section == "HDR" && key == "Float") s_hdr_float = val != "0";
		else if (section == "HDR" && key == "DumpComposite") s_dump_shaders = val != "0";
		else if (section == "HDR" && key == "UpgradeTargets") s_hdr_upgrade = val != "0";
	}
	if (s_inject_slot < 0 || s_inject_slot >= 16)
	{
		logf("BlancoVision.addon inject: slot b%d is not a valid pixel stage register, injection off", s_inject_slot);
		s_inject_enable = false;
	}
	logf("BlancoVision.addon: %zu hash groups from BlancoVision.addon.ini", s_groups.size());
}

// Writes the switches back to the ini, which is where create_swapchain and load_ini read them.
// Every other line is preserved: the hash groups are generated by the build script.
static void save_ini()
{
	const std::string path = base_path() + "BlancoVision.addon.ini";
	const std::pair<const char *, std::string> keys[] = {
		{ "Enable=", std::string(s_replace ? "1" : "0") },        // [Replace], first Enable in the file
		{ "Slot=", std::to_string(s_inject_slot) },
		{ "Group=", s_inject_group },
		{ "FlipModel=", std::string(s_hdr_flip ? "1" : "0") },
		{ "Float=", std::string(s_hdr_float ? "1" : "0") },
		{ "DumpComposite=", std::string(s_dump_shaders ? "1" : "0") },
		{ "UpgradeTargets=", std::string(s_hdr_upgrade ? "1" : "0") },
	};
	std::vector<std::string> lines;
	std::string section;
	bool wrote_inject_enable = false;
	{
		std::ifstream in(path);
		std::string line;
		while (std::getline(in, line))
		{
			while (!line.empty() && line.back() == '\r') line.pop_back();
			if (!line.empty() && line[0] == '[') section = line;
			// Both [Replace] and [Inject] have an Enable, so that one goes by section.
			if (line.rfind("Enable=", 0) == 0 && section == "[Inject]")
			{ line = std::string("Enable=") + (s_inject_enable ? "1" : "0"); wrote_inject_enable = true; }
			else for (const auto &k : keys)
				if (line.rfind(k.first, 0) == 0) { line = k.first + k.second; break; }
			lines.push_back(line);
		}
	}
	std::ofstream out(path, std::ios::trunc);
	if (!out) { logf("BlancoVision.addon: cannot write %s", path.c_str()); return; }
	for (const std::string &l : lines) out << l << "\n";
	if (!wrote_inject_enable) out << "\n[Inject]\nEnable=" << (s_inject_enable ? 1 : 0)
		<< "\nSlot=" << s_inject_slot << "\nGroup=" << s_inject_group << "\n";
	logf("BlancoVision.addon: settings saved; swap chain switches apply on the next launch");
}

static bool group_matches(const std::string &group, uint32_t hash)
{
	if (group.empty()) return true;
	const auto it = s_groups.find(group);
	return it != s_groups.end() && it->second.count(hash) != 0;
}

// ---------------------------------------------------------------------------- rules from effect uniforms
static void collect_rules(effect_runtime *runtime)
{
	std::lock_guard<std::mutex> lock(s_mutex);
	s_rules.clear(); s_targets.clear(); s_injects.clear(); s_inject_upload = true;
	s_enable_var = { 0 }; s_dump_var = { 0 };
	runtime->enumerate_uniform_variables(nullptr, [](effect_runtime *runtime, effect_uniform_variable var) {
		// < bv >, not < source >: a source annotation makes the uniform special and hides its widget.
		char source[32];
		if (!runtime->get_annotation_string_from_uniform_variable(var, "bv", source)) return;
		if (std::strcmp(source, "enable") == 0) { s_enable_var = var; return; }
		if (std::strcmp(source, "dump") == 0) { s_dump_var = var; return; }
		uint32_t rows = 1, cols = 1;
		runtime->get_uniform_variable_type(var, nullptr, &rows, &cols, nullptr);
		int count = static_cast<int>(rows * cols);
		if (count < 1) count = 1;
		if (std::strcmp(source, "inject") == 0)
		{
			Inject in; in.var = var; in.count = count > 16 ? 16 : count;
			runtime->get_annotation_int_from_uniform_variable(var, "bv_offset", &in.offset, 1);
			if (in.offset < 0 || static_cast<size_t>(in.offset + in.count) > INJECT_FLOATS)
			{ logf("BlancoVision.addon: inject uniform at offset %d (%d floats) does not fit the buffer, ignored", in.offset, in.count); return; }
			s_injects.push_back(in);
			return;
		}
		const bool read = std::strcmp(source, "read") == 0;
		if (!read && std::strcmp(source, "patch") != 0) return;
		if (s_rules.size() >= MAX_RULES) { logf("BlancoVision.addon: more than %zu rules, ignoring the rest", MAX_RULES); return; }
		Rule r; r.var = var; r.read = read;
		runtime->get_uniform_variable_name(var, r.name);
		char text[64];
		if (runtime->get_annotation_string_from_uniform_variable(var, "bv_group", text)) r.group = text;
		runtime->get_annotation_int_from_uniform_variable(var, "bv_slot", &r.slot, 1);
		runtime->get_annotation_int_from_uniform_variable(var, "bv_offset", &r.offset, 1);
		runtime->get_annotation_int_from_uniform_variable(var, "bv_size", &r.size, 1);
		if (runtime->get_annotation_string_from_uniform_variable(var, "bv_op", text))
			r.op = std::strcmp(text, "mul") == 0 ? 1 : std::strcmp(text, "add") == 0 ? 2 : 0;
		if (!runtime->get_annotation_int_from_uniform_variable(var, "bv_when_offset", &r.when_offset, 1))
			r.when_offset = -1;
		if (runtime->get_annotation_string_from_uniform_variable(var, "bv_when", text))
		{
			char effect[260] = "";
			runtime->get_uniform_variable_effect_name(var, effect);
			r.when = runtime->find_uniform_variable(effect, text);
		}
		if (runtime->get_annotation_string_from_uniform_variable(var, "bv_switch", text))
		{
			char effect[260] = "";
			// The switch lives in the same effect file as the rule
			runtime->get_uniform_variable_effect_name(var, effect);
			r.sw = runtime->find_uniform_variable(effect, text);
		}
		// A patch writes through Rule::value (4 floats); a read fills readback, wide enough for a matrix.
		const int cap = read ? 16 : 4;
		r.count = count > cap ? cap : count;
		if (r.slot < 0 || r.slot >= 16 || r.offset < 0) { logf("BlancoVision.addon: rule with bad slot/offset ignored"); return; }
		s_rules.push_back(r);
	});
	logf("BlancoVision.addon: %zu rules collected, %zu inject uniform(s)", s_rules.size(), s_injects.size());
}

// Filled once a frame on the presenting thread, so injected values are one frame behind.
static void inject_refresh(effect_runtime *runtime) // s_mutex held
{
	if (!s_inject_enable || s_injects.empty() || s_inject_group.empty()) return;
	float next[INJECT_FLOATS];
	std::memcpy(next, s_inject_data, sizeof(next));
	for (const Inject &in : s_injects)
		runtime->get_uniform_value_float(in.var, next + in.offset, in.count);
	if (!s_inject_upload && std::memcmp(next, s_inject_data, sizeof(next)) == 0) return;
	std::memcpy(s_inject_data, next, sizeof(next));
	device *const dev = runtime->get_device();
	if (s_inject_buf.handle == 0)
	{
		if (!dev->create_resource(resource_desc(sizeof(s_inject_data), memory_heap::default_, resource_usage::constant_buffer),
			nullptr, resource_usage::constant_buffer, &s_inject_buf))
		{
			logf("BlancoVision.addon inject: could not create the constant buffer, injection off");
			s_inject_enable = false; return;
		}
		s_inject_dev = dev;
		logf("BlancoVision.addon inject: %zu byte buffer bound at b%d for group \"%s\", %zu uniform(s)",
			sizeof(s_inject_data), s_inject_slot, s_inject_group.c_str(), s_injects.size());
	}
	else if (dev != s_inject_dev) return; // a second device (FiveM's NUI) never gets the buffer
	s_inject_upload = false;
	dev->update_buffer_region(s_inject_data, s_inject_buf, 0, sizeof(s_inject_data));
}

static void refresh_rules(effect_runtime *runtime, command_list *, resource_view, resource_view)
{
	std::lock_guard<std::mutex> lock(s_mutex);
	inject_refresh(runtime);
	if (s_enable_var.handle != 0) runtime->get_uniform_value_bool(s_enable_var, &s_enabled, 1);
	if (s_dump_var.handle != 0)
	{
		const bool was = s_dump;
		runtime->get_uniform_value_bool(s_dump_var, &s_dump, 1);
		if (s_dump && !was) { s_dumped.clear(); s_last.clear(); s_logged_copies.clear(); } // every toggle on = a fresh snapshot, so states (weather, interior) can be diffed
	}
	for (Rule &r : s_rules)
	{
		if (r.read)
		{
			if (r.have_readback) runtime->set_uniform_value_float(r.var, r.readback, r.count);
			r.active = r.effective = s_enabled; // a read never writes, so it is always safe to run
			continue;
		}
		bool on = true;
		if (r.sw.handle != 0) runtime->get_uniform_value_bool(r.sw, &on, 1);
		if (r.when.handle != 0) runtime->get_uniform_value_float(r.when, r.when_range, 2);
		r.active = s_enabled && on;
		runtime->get_uniform_value_float(r.var, r.value, r.count);
		// A rule at its neutral value must not claim the buffer: claiming it takes over the upload and
		// discards any other add-on edit to the same constants. Only rules that move a number intercept.
		bool neutral = false;
		if (r.op == 1) { neutral = true; for (int k = 0; k < r.count; ++k) if (r.value[k] != 1.0f) neutral = false; }
		else if (r.op == 2) { neutral = true; for (int k = 0; k < r.count; ++k) if (r.value[k] != 0.0f) neutral = false; }
		r.effective = r.active && !neutral;
	}
	s_effective_mask.clear();
	for (size_t i = 0; i < s_rules.size(); ++i)
		if (s_rules[i].effective) s_effective_mask.set(i);
}

// ---------------------------------------------------------------------------- 1. shader replacement
static bool on_create_pipeline(device *, pipeline_layout, uint32_t subobject_count, const pipeline_subobject *subobjects)
{
	if (!s_replace && !s_dump_shaders) return false;
	bool replaced = false;
	for (uint32_t i = 0; i < subobject_count; ++i)
	{
		if (subobjects[i].type != pipeline_subobject_type::pixel_shader && subobjects[i].type != pipeline_subobject_type::vertex_shader && subobjects[i].type != pipeline_subobject_type::compute_shader) continue;
		shader_desc &desc = *static_cast<shader_desc *>(subobjects[i].data);
		if (desc.code_size == 0) continue;
		const uint32_t hash = crc32(static_cast<const uint8_t *>(desc.code), desc.code_size);
		// Composite group only, so this is a handful of files and not every shader in the game.
		if (s_dump_shaders && group_matches("composite", hash) && s_dumped_shaders.insert(hash).second)
		{
			const std::string dir = base_path() + "BlancoVision_dump";
			CreateDirectoryA(dir.c_str(), nullptr);
			char leaf[32];
			snprintf(leaf, sizeof(leaf), "\\0x%08X.cso", hash);
			std::ofstream f(dir + leaf, std::ios::binary);
			if (f) { f.write(static_cast<const char *>(desc.code), static_cast<std::streamsize>(desc.code_size));
				logf("BlancoVision.addon dump: shader 0x%08X, %zu bytes", hash, desc.code_size); }
		}
		if (!s_replace) continue;
		// Keep the original hash: init_pipeline sees the same array, by then holding the replacement,
		// and a hash of that matches nothing in [Groups], which would kill patching on replaced shaders.
		if (subobjects[i].type == pipeline_subobject_type::pixel_shader) s_original_hash = hash;
		char name[64]; snprintf(name, sizeof(name), "BlancoVision\\0x%08X.cso", hash);
		std::ifstream file(base_path() + name, std::ios::binary);
		if (!file) continue;
		std::vector<uint8_t> code((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
		if (code.empty()) continue;
		s_replaced_code.push_back(std::move(code));
		desc.code = s_replaced_code.back().data(); desc.code_size = s_replaced_code.back().size();
		replaced = true; ++s_replaced_count;
	}
	return replaced;
}
static void on_init_pipeline(device *, pipeline_layout, uint32_t subobject_count, const pipeline_subobject *subobjects, pipeline handle)
{
	for (uint32_t i = 0; i < subobject_count; ++i)
	{
		if (subobjects[i].type != pipeline_subobject_type::pixel_shader) continue;
		const shader_desc &desc = *static_cast<const shader_desc *>(subobjects[i].data);
		if (desc.code_size == 0) continue;
		// Set only when create_pipeline ran for this pipeline; otherwise desc.code is still the game blob.
		const uint32_t hash = s_original_hash != 0 ? s_original_hash : crc32(static_cast<const uint8_t *>(desc.code), desc.code_size);
		std::lock_guard<std::mutex> lock(s_mutex);
		s_pipeline_hash[handle.handle] = hash;
	}
	// Freed only now: create_pipeline pointed desc.code into these.
	s_replaced_code.clear();
	s_original_hash = 0;
}
static void on_destroy_pipeline(device *, pipeline handle)
{
	std::lock_guard<std::mutex> lock(s_mutex);
	s_pipeline_hash.erase(handle.handle);
}
// D3D11 recycles buffer addresses, so without this a new buffer inherits a dead one rule mask.
static void on_destroy_resource(device *, resource res)
{
	std::lock_guard<std::mutex> lock(s_mutex);
	s_targets.erase(res.handle);
	s_upgraded_res.erase(res.handle);
	s_base.erase(res.handle);
	s_last.erase(res.handle);
	s_mapped.erase(res.handle);
}
static void on_destroy_device(device *dev)
{
	std::lock_guard<std::mutex> lock(s_mutex);
	if (dev != s_inject_dev || s_inject_buf.handle == 0) return;
	dev->destroy_resource(s_inject_buf);
	s_inject_buf = { 0 }; s_inject_dev = nullptr; s_inject_upload = true;
}
static void on_destroy_command_list(command_list *cmd)
{
	std::lock_guard<std::mutex> lock(s_mutex);
	s_cmd.erase(cmd);
}

// ---------------------------------------------------------------------------- 2/3. tracking what each draw binds
static void on_bind_pipeline(command_list *cmd, pipeline_stage stages, pipeline handle)
{
	if ((static_cast<uint32_t>(stages) & static_cast<uint32_t>(pipeline_stage::pixel_shader)) == 0) return;
	std::lock_guard<std::mutex> lock(s_mutex);
	const auto it = s_pipeline_hash.find(handle.handle);
	s_cmd[cmd].ps_hash = it != s_pipeline_hash.end() ? it->second : 0;
}
// Which target a draw writes to. Only read under < bv = "dump" >.
static void on_bind_render_targets(command_list *cmd, uint32_t count, const resource_view *rtvs, resource_view)
{
	if (!s_dump && !s_dump_shaders) return;
	std::lock_guard<std::mutex> lock(s_mutex);
	s_cmd[cmd].rtv = count != 0 ? rtvs[0].handle : 0;
}
static void on_push_descriptors(command_list *cmd, shader_stage stages, pipeline_layout, uint32_t, const descriptor_table_update &update)
{
	if ((static_cast<uint32_t>(stages) & static_cast<uint32_t>(shader_stage::pixel)) == 0) return;
	// API 20 and up only, and inert on D3D11; the guard keeps this buildable against an older SDK.
	if (update.type != descriptor_type::constant_buffer
#if RESHADE_API_VERSION >= 20
		&& update.type != descriptor_type::constant_buffer_with_dynamic_offset
#endif
		) return;
	const buffer_range *ranges = static_cast<const buffer_range *>(update.descriptors);
	std::lock_guard<std::mutex> lock(s_mutex);
	CmdState &st = s_cmd[cmd];
	for (uint32_t i = 0; i < update.count; ++i)
	{
		const uint32_t slot = update.binding + i;
		// PSSetConstantBuffers1 binds a sub-range, so remember its base; rule offsets are from the start.
		if (slot < 16) { st.cb[slot] = ranges[i].buffer.handle; st.cb_first[slot] = ranges[i].offset / 4; }
	}
}
static void on_draw_any(command_list *cmd)
{
	std::lock_guard<std::mutex> lock(s_mutex);
	const auto it = s_cmd.find(cmd);
	if (it == s_cmd.end() || it->second.ps_hash == 0) return;
	const CmdState &st = it->second;
	// Bind the injection buffer before this draw. D3D11 binding is sticky, so [Inject] Slot must be
	// a register nothing else uses.
	if (s_enabled && s_inject_enable && s_inject_buf.handle != 0 && !s_inject_group.empty()
		&& group_matches(s_inject_group, st.ps_hash) && cmd->get_device() == s_inject_dev)
	{
		const buffer_range range = { s_inject_buf, 0, UINT64_MAX };
		const descriptor_table_update update = { { 0 }, static_cast<uint32_t>(s_inject_slot), 0, 1, descriptor_type::constant_buffer, &range };
		cmd->push_descriptors(shader_stage::pixel, pipeline_layout { 0 }, 0, update);
	}
	for (size_t i = 0; i < s_rules.size(); ++i)
	{
		const Rule &r = s_rules[i];
		if (!r.effective) continue; // neutral rules never claim a buffer, so other add-ons keep it
		const uint64_t buf = st.cb[r.slot];
		if (buf == 0 || !group_matches(r.group, st.ps_hash)) continue;
		s_targets[buf].set(i);
		s_rules[i].seen_buffer = true;
		// Sub-range base for apply() to shift the rule offset by. Zero for a plain bind.
		s_base[buf] = st.cb_first[r.slot];
	}
	if (s_dump || s_dump_shaders)
	{
		for (uint32_t slot = 0; slot < 16; ++slot)
		{
			const uint64_t buf = st.cb[slot];
			if (buf == 0) continue;
			const uint64_t key = (static_cast<uint64_t>(st.ps_hash) << 8) | slot;
			if (s_dumped.count(key)) continue;
			const auto lt = s_last.find(buf);
			if (lt == s_last.end()) continue; // nothing uploaded since dump mode went on
			s_dumped.insert(key);
			std::string line; char num[32];
			for (size_t k = 0; k < lt->second.floats.size(); ++k) { snprintf(num, sizeof(num), "%s%g", k ? " " : "", lt->second.floats[k]); line += num; }
			// The byte size is what bv_size needs, so log it, not just the float count.
			logf("BlancoVision.addon dump: ps 0x%08X b%u size %llu bytes, first %zu floats: %s",
				st.ps_hash, slot, static_cast<unsigned long long>(lt->second.total), lt->second.floats.size(), line.c_str());
		}
		// Render target of this pass, once per pixel shader. Format numbers are DXGI ones.
		const uint64_t rt_key = (static_cast<uint64_t>(st.ps_hash) << 8) | 0xFF;
		if (st.rtv != 0 && s_dumped.insert(rt_key).second)
		{
			device *const dev = cmd->get_device();
			resource_view view; view.handle = st.rtv;
			const resource res = dev->get_resource_from_view(view);
			const resource_desc rd = dev->get_resource_desc(res);
			logf("BlancoVision.addon rt: ps 0x%08X -> res %llX format %u %ux%u%s",
				st.ps_hash, static_cast<unsigned long long>(res.handle), static_cast<unsigned>(rd.texture.format),
				rd.texture.width, rd.texture.height, s_backbuffers.count(res.handle) ? " BACKBUFFER" : "");
		}
	}
}
// DXGI refuses every HDR colour space on a blit model swap chain, which is what the game asks for.
// The size and buffer count test keeps this to the game window, not small UI swap chains.
static bool on_create_swapchain(device_api api, swapchain_desc &desc, void *)
{
	if (api != device_api::d3d11 || (!s_hdr_flip && !s_hdr_float)) return false;
	if (desc.back_buffer.texture.width < 640 || desc.back_buffer_count < 2 || desc.back_buffer.texture.samples > 1) return false;
	const uint32_t was_mode = desc.present_mode;
	const format was_format = desc.back_buffer.texture.format;
	if (s_hdr_flip && (desc.present_mode == 0 /* DISCARD */ || desc.present_mode == 1 /* SEQUENTIAL */))
		desc.present_mode = 4; // DXGI_SWAP_EFFECT_FLIP_DISCARD
	if (s_hdr_float)
		desc.back_buffer.texture.format = format::r16g16b16a16_float;
	const bool changed = desc.present_mode != was_mode || desc.back_buffer.texture.format != was_format;
	if (changed)
		logf("BlancoVision.addon hdr: swap chain %ux%u, present mode %u -> %u, format %u -> %u",
			desc.back_buffer.texture.width, desc.back_buffer.texture.height, was_mode, desc.present_mode,
			static_cast<unsigned>(was_format), static_cast<unsigned>(desc.back_buffer.texture.format));
	return changed;
}
// A copy carries no pixel shader, so the render target probe cannot see it. Report copies into a
// back buffer instead, once per source and destination pair.
static void log_copy(command_list *cmd, resource source, resource dest, const char *how)
{
	if (!s_dump && !s_dump_shaders) return;
	std::lock_guard<std::mutex> lock(s_mutex);
	if (s_backbuffers.count(dest.handle) == 0) return;
	const uint64_t key = source.handle ^ (dest.handle << 1);
	if (!s_logged_copies.insert(key).second) return;
	device *const dev = cmd->get_device();
	const resource_desc sd = dev->get_resource_desc(source), dd = dev->get_resource_desc(dest);
	logf("BlancoVision.addon copy: %s, src res %llX format %u %ux%u -> BACKBUFFER res %llX format %u %ux%u",
		how, static_cast<unsigned long long>(source.handle), static_cast<unsigned>(sd.texture.format),
		sd.texture.width, sd.texture.height,
		static_cast<unsigned long long>(dest.handle), static_cast<unsigned>(dd.texture.format),
		dd.texture.width, dd.texture.height);
}
// Exact match only. A blanket rule would also catch UI and scratch surfaces and break them.
static bool on_create_resource(device *, resource_desc &desc, subresource_data *, resource_usage)
{
	if (!s_hdr_upgrade || desc.type != resource_type::texture_2d) return false;
	if (desc.texture.format != format::b8g8r8a8_unorm && desc.texture.format != format::b8g8r8a8_typeless) return false;
	if (desc.texture.levels != 1 || desc.texture.depth_or_layers != 1 || desc.texture.samples != 1) return false;
	if (desc.texture.width < 1280 || desc.texture.height < 720) return false;
	const uint32_t need = static_cast<uint32_t>(resource_usage::render_target) | static_cast<uint32_t>(resource_usage::shader_resource);
	if ((static_cast<uint32_t>(desc.usage) & need) != need) return false;
	desc.texture.format = format::r16g16b16a16_float;
	s_upgrade_pending = true;
	logf(" BlancoVision.addon hdr: upgraded a %ux%u BGRA8 target to RGBA16F (%u so far)",
		desc.texture.width, desc.texture.height, ++s_upgraded);
	return true;
}
// init_resource fires right after its create_resource, so the flag identifies the handle here.
static void on_init_resource(device *, const resource_desc &, const subresource_data *, resource_usage, resource res)
{
	if (!s_upgrade_pending) return;
	s_upgrade_pending = false;
	std::lock_guard<std::mutex> lock(s_mutex);
	s_upgraded_res.insert(res.handle);
}
// D3D11 views carry their own format and a mismatched view fails to create, silently. Every view
// onto an upgraded resource has to be retyped or the target renders black.
static bool on_create_resource_view(device *, resource resource, resource_usage, resource_view_desc &desc)
{
	if (!s_hdr_upgrade) return false;
	{
		std::lock_guard<std::mutex> lock(s_mutex);
		if (s_upgraded_res.count(resource.handle) == 0) return false;
	}
	if (desc.format == format::r16g16b16a16_float) return false;
	desc.format = format::r16g16b16a16_float;
	return true;
}
static bool on_copy_resource(command_list *cmd, resource source, resource dest)
{
	log_copy(cmd, source, dest, "CopyResource");
	return false;
}
static bool on_copy_texture_region(command_list *cmd, resource source, uint32_t, const subresource_box *, resource dest, uint32_t, const subresource_box *, filter_mode)
{
	log_copy(cmd, source, dest, "CopyTextureRegion");
	return false;
}
static bool on_resolve_texture_region(command_list *cmd, resource source, uint32_t, const subresource_box *, resource dest, uint32_t, uint32_t, uint32_t, uint32_t, format)
{
	log_copy(cmd, source, dest, "ResolveTextureRegion");
	return false;
}
// Present format, colour space in use, and whether scRGB is offered on this display.
static void on_init_swapchain(swapchain *sc, bool)
{
	std::lock_guard<std::mutex> lock(s_mutex);
	s_backbuffers.clear();
	device *const dev = sc->get_device();
	const uint32_t count = sc->get_back_buffer_count();
	for (uint32_t i = 0; i < count; ++i)
	{
		const resource bb = sc->get_back_buffer(i);
		s_backbuffers.insert(bb.handle);
		if (i != 0) continue;
		const resource_desc rd = dev->get_resource_desc(bb);
		logf("BlancoVision.addon swapchain: %u back buffers, format %u %ux%u, colour space %u, scRGB %s, HDR10 %s",
			count, static_cast<unsigned>(rd.texture.format), rd.texture.width, rd.texture.height,
			static_cast<unsigned>(sc->get_color_space()),
			sc->check_color_space_support(color_space::extended_srgb_linear) ? "supported" : "no",
			sc->check_color_space_support(color_space::hdr10_st2084) ? "supported" : "no");
	}
}
static bool on_draw(command_list *cmd, uint32_t, uint32_t, uint32_t, uint32_t) { on_draw_any(cmd); return false; }
static bool on_draw_indexed(command_list *cmd, uint32_t, uint32_t, uint32_t, int32_t, uint32_t) { on_draw_any(cmd); return false; }

// Rule bits for this buffer, masked to the rules currently changing a value. A buffer stops being
// claimed as soon as its slider returns to neutral.
static Mask targeted(uint64_t buf)
{
	const auto tt = s_targets.find(buf);
	return tt != s_targets.end() ? (tt->second & s_effective_mask) : Mask();
}

// Apply the rules that target this buffer to CPU memory holding bytes [offset, offset + size) of it.
static void apply(uint64_t buf, float *data, uint64_t offset, uint64_t size, uint64_t total)
{
	const Mask mask = targeted(buf);
	if (s_dump)
	{
		Snapshot &last = s_last[buf];
		last.total = total;
		last.floats.assign(data, data + (size / 4 < DUMP_FLOATS ? size / 4 : DUMP_FLOATS));
	}
	if (!mask.any() || !s_enabled) return;
	for (size_t i = 0; i < s_rules.size(); ++i)
	{
		if (!mask.test(i)) continue;
		Rule &r = s_rules[i];
		if (!r.effective || (r.size != 0 && static_cast<uint64_t>(r.size) != total)) continue;
		const auto bt = s_base.find(buf);
		const int64_t base = bt != s_base.end() ? static_cast<int64_t>(bt->second) : 0;
		const int64_t first = static_cast<int64_t>(r.offset) + base - static_cast<int64_t>(offset / 4);
		if (first < 0 || static_cast<uint64_t>(first + r.count) * 4 > size) continue;
		if (r.when_offset >= 0)
		{
			const int64_t at = static_cast<int64_t>(r.when_offset) + base - static_cast<int64_t>(offset / 4);
			if (at < 0 || static_cast<uint64_t>(at + 1) * 4 > size) continue;
			const float v = data[at];
			if (v < r.when_range[0] || v > r.when_range[1]) continue;
		}
		float *p = data + first;
		if (r.read) { for (int k = 0; k < r.count; ++k) r.readback[k] = p[k]; r.have_readback = true; ++r.writes; continue; }
		for (int k = 0; k < r.count; ++k)
			p[k] = r.op == 1 ? p[k] * r.value[k] : r.op == 2 ? p[k] + r.value[k] : r.value[k];
		++r.writes;
	}
}
static void on_map_buffer_region(device *, resource res, uint64_t offset, uint64_t, map_access access, void **data)
{
	if (access == map_access::read_only || data == nullptr || *data == nullptr) return;
	std::lock_guard<std::mutex> lock(s_mutex);
	if (!targeted(res.handle).any() && !s_dump) return;
	s_mapped[res.handle] = { *data, offset };
}
static void on_unmap_buffer_region(device *dev, resource res)
{
	std::lock_guard<std::mutex> lock(s_mutex);
	const auto it = s_mapped.find(res.handle);
	if (it == s_mapped.end()) return;
	const resource_desc desc = dev->get_resource_desc(res);
	const uint64_t size = desc.type == resource_type::buffer ? desc.buffer.size - it->second.offset : 0;
	if (size > 0) apply(res.handle, static_cast<float *>(it->second.data), it->second.offset, size, desc.buffer.size);
	s_mapped.erase(it);
}
static bool on_update_buffer_region(device *dev, const void *data, resource res, uint64_t offset, uint64_t size)
{
	std::lock_guard<std::mutex> lock(s_mutex);
	if (!targeted(res.handle).any() && !s_dump) return false;
	const resource_desc desc = dev->get_resource_desc(res);
	const uint64_t total = desc.type == resource_type::buffer ? desc.buffer.size : 0;
	// Size is UINT64_MAX when the app passes a null box. Clamp, or apply() reads past small buffers.
	if (total == 0) return false;
	if (offset >= total) return false;
	if (size > total - offset) size = total - offset;
	// The source is the app own memory, so patch a copy: in place would compound every "mul" rule
	// each frame if the engine reuses the allocation, and corrupt state it may read back.
	std::vector<float> scratch(static_cast<size_t>(size / 4));
	if (scratch.empty()) return false;
	std::memcpy(scratch.data(), data, scratch.size() * sizeof(float));
	apply(res.handle, scratch.data(), offset, size, total);
	if (!targeted(res.handle).any() || !s_enabled) return false; // dump only, nothing was patched
	// This goes to the original immediate context, so it does not re-enter this handler.
	dev->update_buffer_region(scratch.data(), res, offset, size);
	return true; // the patched copy has been uploaded; suppress the original
}

// Deferred-context UpdateSubresource. The command list records the copy, so re-uploading would
// reorder; patch in place instead, which is safe because the data is recorded, not reused.
static bool on_update_buffer_region_command(command_list *cmd, const void *data, resource res, uint64_t offset, uint64_t size)
{
	device *const dev = cmd->get_device();
	std::lock_guard<std::mutex> lock(s_mutex);
	if (!targeted(res.handle).any() && !s_dump) return false;
	const resource_desc desc = dev->get_resource_desc(res);
	const uint64_t total = desc.type == resource_type::buffer ? desc.buffer.size : 0;
	if (total == 0 || offset >= total) return false;
	if (size > total - offset) size = total - offset;
	apply(res.handle, const_cast<float *>(static_cast<const float *>(data)), offset, size, total);
	return false;
}

// The add-on window in the ReShade overlay. Rules stay where they are, in the effect's own panel;
// this covers the settings that live in the ini and the counters that say whether anything works.
static void draw_overlay(effect_runtime *runtime)
{
	std::lock_guard<std::mutex> lock(s_mutex);
	bool save = false;

	if (s_enable_var.handle != 0)
	{
		if (ImGui::Checkbox("Apply patches", &s_enabled)) runtime->set_uniform_value_bool(s_enable_var, &s_enabled, 1);
		if (ImGui::Checkbox("Log constant buffers to ReShade.log", &s_dump))
		{
			runtime->set_uniform_value_bool(s_dump_var, &s_dump, 1);
			if (s_dump) { s_dumped.clear(); s_last.clear(); s_logged_copies.clear(); }
		}
	}
	else
	{
		ImGui::TextUnformatted("No control effect loaded. Enable BlancoVision_Control.fx for the rules.");
	}

	ImGui::Text("%zu rule(s), %zu inject uniform(s), %u shader(s) replaced", s_rules.size(), s_injects.size(), s_replaced_count);
	for (const auto &g : s_groups)
		ImGui::Text("group \"%s\": %zu hash(es)%s", g.first.c_str(), g.second.size(), g.second.empty() ? " (matches nothing)" : "");

	ImGui::SeparatorText("Shader replacement");
	if (ImGui::Checkbox("Replace shaders by hash", &s_replace)) save = true;
	if (ImGui::Checkbox("Dump composite shaders to BlancoVision_dump", &s_dump_shaders)) save = true;

	ImGui::SeparatorText("Injection");
	if (ImGui::Checkbox("Bind the injection buffer", &s_inject_enable)) save = true;
	if (ImGui::SliderInt("Register (pixel stage)", &s_inject_slot, 0, 15)) save = true;
	ImGui::SetItemTooltip("Must be a register the game does not use. D3D11 binding is sticky.");
	char group[64];
	snprintf(group, sizeof(group), "%s", s_inject_group.c_str());
	if (ImGui::InputText("Hash group", group, sizeof(group))) { s_inject_group = group; save = true; }
	ImGui::SetItemTooltip("Empty turns injection off.");
	ImGui::Text(s_inject_buf.handle != 0 ? "Buffer live, %zu floats" : "No buffer yet (needs an inject uniform)", INJECT_FLOATS);

	ImGui::SeparatorText("HDR output (next launch)");
	if (ImGui::Checkbox("Flip model swap chain", &s_hdr_flip)) save = true;
	ImGui::SetItemTooltip("DXGI refuses every HDR colour space on the blit model swap chain the game asks for.");
	if (ImGui::Checkbox("RGBA16F scRGB presentation", &s_hdr_float)) save = true;
	if (ImGui::Checkbox("Upgrade 8 bit composite targets to float", &s_hdr_upgrade)) save = true;

	if (ImGui::CollapsingHeader("Which settings are reaching the game"))
	{
		ImGui::TextWrapped("Move a slider off its default, then look here. A rule that never finds a "
			"buffer has the wrong register or size for this build. One that finds a buffer but never "
			"writes is sitting at its neutral value, which is normal until you move it.");
		unsigned live = 0, idle = 0, missing = 0;
		if (ImGui::BeginTable("bvdiag", 3, ImGuiTableFlags_RowBg | ImGuiTableFlags_SizingStretchProp))
		{
			ImGui::TableSetupColumn("setting");
			ImGui::TableSetupColumn("register");
			ImGui::TableSetupColumn("writes");
			ImGui::TableHeadersRow();
			for (const Rule &r : s_rules)
			{
				const bool no_buffer = !r.seen_buffer;
				if (no_buffer) ++missing; else if (r.writes != 0) ++live; else ++idle;
				ImGui::TableNextRow();
				ImGui::TableNextColumn();
				if (no_buffer) ImGui::TextColored(ImVec4(1.0f, 0.45f, 0.35f, 1.0f), "%s", r.name);
				else if (r.writes != 0) ImGui::TextColored(ImVec4(0.45f, 0.9f, 0.5f, 1.0f), "%s", r.name);
				else ImGui::TextDisabled("%s", r.name);
				ImGui::TableNextColumn();
				ImGui::Text("b%d/%d", r.slot, r.size);
				ImGui::TableNextColumn();
				if (no_buffer) ImGui::TextUnformatted("no such buffer");
				else ImGui::Text("%llu", static_cast<unsigned long long>(r.writes));
			}
			ImGui::EndTable();
		}
		ImGui::Text("%u writing, %u idle at their default, %u never found a buffer", live, idle, missing);
	}

	ImGui::Separator();
	if (ImGui::Button("Reload BlancoVision.addon.ini")) load_ini();
	if (save) save_ini();
}

static void on_init_effect_runtime(effect_runtime *runtime)
{
	std::lock_guard<std::mutex> lock(s_mutex);
	load_ini();
	if (s_hdr_float)
	{
		runtime->set_color_space(color_space::extended_srgb_linear);
		logf("BlancoVision.addon hdr: presentation colour space set to scRGB");
	}
}
static void on_reloaded_effects(effect_runtime *runtime)
{
	collect_rules(runtime);
	logf("BlancoVision.addon: %u shader(s) replaced so far", s_replaced_count);
}

extern "C" __declspec(dllexport) const char *NAME = "BlancoVision";
extern "C" __declspec(dllexport) const char *DESCRIPTION = "Shader replacement by hash, constant buffer patching, read back and injection, all driven by effect uniforms (see BlancoVision_Control.fx).";

BOOL APIENTRY DllMain(HMODULE hModule, DWORD fdwReason, LPVOID)
{
	switch (fdwReason)
	{
	case DLL_PROCESS_ATTACH:
		if (!reshade::register_addon(hModule)) return FALSE;
		load_ini(); // the HDR switches are needed at create_swapchain, before any effect runtime
		reshade::register_event<reshade::addon_event::create_pipeline>(on_create_pipeline);
		reshade::register_event<reshade::addon_event::init_pipeline>(on_init_pipeline);
		reshade::register_event<reshade::addon_event::destroy_pipeline>(on_destroy_pipeline);
		reshade::register_event<reshade::addon_event::destroy_resource>(on_destroy_resource);
		reshade::register_event<reshade::addon_event::destroy_device>(on_destroy_device);
		reshade::register_event<reshade::addon_event::destroy_command_list>(on_destroy_command_list);
		reshade::register_event<reshade::addon_event::bind_pipeline>(on_bind_pipeline);
		reshade::register_event<reshade::addon_event::bind_render_targets_and_depth_stencil>(on_bind_render_targets);
		reshade::register_event<reshade::addon_event::create_swapchain>(on_create_swapchain);
		reshade::register_event<reshade::addon_event::create_resource>(on_create_resource);
		reshade::register_event<reshade::addon_event::init_resource>(on_init_resource);
		reshade::register_event<reshade::addon_event::create_resource_view>(on_create_resource_view);
		reshade::register_event<reshade::addon_event::copy_resource>(on_copy_resource);
		reshade::register_event<reshade::addon_event::copy_texture_region>(on_copy_texture_region);
		reshade::register_event<reshade::addon_event::resolve_texture_region>(on_resolve_texture_region);
		reshade::register_event<reshade::addon_event::init_swapchain>(on_init_swapchain);
		reshade::register_event<reshade::addon_event::push_descriptors>(on_push_descriptors);
		reshade::register_event<reshade::addon_event::draw>(on_draw);
		reshade::register_event<reshade::addon_event::draw_indexed>(on_draw_indexed);
		reshade::register_event<reshade::addon_event::map_buffer_region>(on_map_buffer_region);
		reshade::register_event<reshade::addon_event::unmap_buffer_region>(on_unmap_buffer_region);
		reshade::register_event<reshade::addon_event::update_buffer_region>(on_update_buffer_region);
		// A deferred context raises this instead, and without it those cbuffers are invisible.
		reshade::register_event<reshade::addon_event::update_buffer_region_command>(on_update_buffer_region_command);
		reshade::register_event<reshade::addon_event::init_effect_runtime>(on_init_effect_runtime);
		reshade::register_event<reshade::addon_event::reshade_reloaded_effects>(on_reloaded_effects);
		reshade::register_event<reshade::addon_event::reshade_begin_effects>(refresh_rules);
		reshade::register_overlay("BlancoVision", draw_overlay);
		break;
	case DLL_PROCESS_DETACH:
		reshade::unregister_addon(hModule);
		break;
	}
	return TRUE;
}
