//////////////////////////////////////////////////////////////////////
// This file is part of Remere's Map Editor
//////////////////////////////////////////////////////////////////////
// Remere's Map Editor is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Remere's Map Editor is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <http://www.gnu.org/licenses/>.
//////////////////////////////////////////////////////////////////////

#include "main.h"

#include "copybuffer.h"
#include "editor.h"
#include "gui.h"
#include "creature.h"
#include "iomap_otbm.h"
#include "graphics.h"
#include "spawn.h"

#include <filesystem>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <nlohmann/json.hpp>

namespace {
using SceneJson = nlohmann::json;
constexpr size_t MaxSceneBytes = 64 * 1024 * 1024;
constexpr size_t MaxSceneItems = 100000;

std::filesystem::path SceneDirectory() {
	wxString directory;
	if (wxGetEnv("TIBIA_ASEPRITE_EXCHANGE", &directory) && !directory.empty()) {
		return std::filesystem::path(directory.ToStdWstring());
	}
	return std::filesystem::path(L"C:/Users/Allan/Aseprite_tibia/runtime");
}

SceneJson PositionJson(const Position& position) {
	return {{"x", position.x}, {"y", position.y}, {"z", position.z}};
}

Position ReadPosition(const SceneJson& value) {
	Position position(value.at("x").get<int>(), value.at("y").get<int>(), value.at("z").get<int>());
	if (!position.isValid()) {
		throw std::runtime_error("Scene contains an invalid map position.");
	}
	return position;
}

std::string HexBytes(const uint8_t* bytes, size_t size) {
	static constexpr char digits[] = "0123456789abcdef";
	std::string result(size * 2, '0');
	for (size_t i = 0; i < size; ++i) {
		result[i * 2] = digits[bytes[i] >> 4];
		result[i * 2 + 1] = digits[bytes[i] & 15];
	}
	return result;
}

std::vector<uint8_t> UnhexBytes(const std::string& hex) {
	if (hex.size() < 10 || hex.size() % 2 != 0 || hex.size() > MaxSceneBytes) {
		throw std::runtime_error("Invalid item OTBM payload length.");
	}
	auto digit = [](char c) -> unsigned {
		if (c >= '0' && c <= '9') return c - '0';
		if (c >= 'a' && c <= 'f') return c - 'a' + 10;
		if (c >= 'A' && c <= 'F') return c - 'A' + 10;
		throw std::runtime_error("Invalid hexadecimal item data.");
	};
	std::vector<uint8_t> bytes(hex.size() / 2);
	for (size_t i = 0; i < bytes.size(); ++i) {
		bytes[i] = static_cast<uint8_t>((digit(hex[i * 2]) << 4) | digit(hex[i * 2 + 1]));
	}
	return bytes;
}

// Validate before calling the legacy BinaryNode reader: it expects a well formed
// node tree and may otherwise walk through a missing parent or truncated escape.
void ValidateItemTree(const std::vector<uint8_t>& bytes) {
	struct State { size_t data = 0; bool children = false; };
	std::vector<State> stack;
	size_t nodeCount = 0;
	for (size_t i = 0; i < bytes.size(); ++i) {
		uint8_t byte = bytes[i];
		if (byte == NODE_START) {
			if ((stack.empty() && i != 0) || stack.size() >= 64 || ++nodeCount > MaxSceneItems) {
				throw std::runtime_error("Invalid item OTBM tree depth or node count.");
			}
			if (!stack.empty()) stack.back().children = true;
			stack.push_back({});
		} else if (byte == NODE_END) {
			if (stack.empty() || stack.back().data < 3) throw std::runtime_error("Truncated item node.");
			stack.pop_back();
			if (stack.empty() && i != bytes.size() - 1) throw std::runtime_error("Extra data after item node.");
		} else {
			if (stack.empty() || stack.back().children) throw std::runtime_error("Invalid data in item tree.");
			if (byte == ESCAPE_CHAR) {
				if (++i == bytes.size()) throw std::runtime_error("Truncated OTBM escape.");
				byte = bytes[i];
			}
			if (stack.back().data == 0 && byte != OTBM_ITEM) throw std::runtime_error("Scene payload is not an OTBM item node.");
			++stack.back().data;
		}
	}
	if (!stack.empty() || nodeCount == 0) throw std::runtime_error("Unclosed item OTBM node.");
}

SceneJson VisualJson(const Item& item, const Tile& tile) {
	const ItemType& type = g_items[item.getID()];
	const GameSprite* sprite = type.sprite;
	if (!sprite) return SceneJson::object();
	const Position& pos = tile.getPosition();
	int x = pos.x % std::max<int>(1, sprite->pattern_x);
	int y = pos.y % std::max<int>(1, sprite->pattern_y);
	int z = pos.z % std::max<int>(1, sprite->pattern_z);
	int subtype = -1;
	if (type.isSplash() || type.isFluidContainer()) {
		subtype = item.getSubtype();
	} else if (type.isHangable) {
		x = tile.hasProperty(HOOK_SOUTH) ? 1 : tile.hasProperty(HOOK_EAST) ? 2 : 0;
	} else if (type.stackable) {
		const int count = item.getSubtype();
		subtype = count <= 4 ? std::max(0, count - 1) : count < 10 ? 4 : count < 25 ? 5 : count < 50 ? 6 : 7;
	}
	return {{"patternX", x}, {"patternY", y}, {"patternZ", z}, {"frame", 0}, {"group", 0},
		{"subtype", subtype}, {"offsetX", sprite->getDrawOffset().first}, {"offsetY", sprite->getDrawOffset().second}, {"drawHeight", sprite->getDrawHeight()}};
}

SceneJson ExportSceneItem(const Item& item, const Tile& tile, const IOMap& codec, bool ground) {
	MemoryNodeFileWriteHandle output;
	if (!item.serializeItemNode_OTBM(codec, output) || output.error_code != FILE_NO_ERROR) {
		throw std::runtime_error("Could not serialize item " + std::to_string(item.getID()) + ".");
	}
	return {{"serverId", item.getID()}, {"clientId", item.getClientID()}, {"ground", ground},
		{"count", item.getSubtype()}, {"otbmHex", HexBytes(output.getData(), output.getSize())}, {"visual", VisualJson(item, tile)}};
}

std::unique_ptr<Item> ImportSceneItem(const SceneJson& value, const IOMap& codec) {
	const int serverId = value.at("serverId").get<int>();
	const int clientId = value.at("clientId").get<int>();
	if (serverId <= 0 || serverId > 65535 || !g_items.typeExists(static_cast<uint16_t>(serverId)) || g_items[serverId].clientID != clientId) {
		throw std::runtime_error("Scene item IDs do not match the active items.otb: " + std::to_string(serverId) + ".");
	}
	auto bytes = UnhexBytes(value.at("otbmHex").get<std::string>());
	ValidateItemTree(bytes);
	MemoryNodeFileReadHandle input(bytes.data(), bytes.size());
	BinaryNode* node = input.getRootNode();
	uint8_t type;
	if (!node || !node->getU8(type) || type != OTBM_ITEM) throw std::runtime_error("Invalid scene item node.");
	std::unique_ptr<Item> item(Item::Create_OTBM(codec, node, nullptr, true));
	if (!item || item->getID() != serverId || !item->unserializeItemNode_OTBM(codec, node) || input.error_code != FILE_NO_ERROR) {
		throw std::runtime_error("Failed to restore item attributes for " + std::to_string(serverId) + ".");
	}
	if (item->hasSubtype() && value.contains("count") && value.at("count").get<int>() != item->getSubtype()) {
		throw std::runtime_error("Scene subtype disagrees with native item attributes.");
	}
	// Refuse any lossy restoration, including unknown attributes or a mismatched
	// container definition, before touching the user's copy buffer or map.
	MemoryNodeFileWriteHandle verified;
	if (!item->serializeItemNode_OTBM(codec, verified) || verified.getSize() != bytes.size() ||
		!std::equal(bytes.begin(), bytes.end(), verified.getData())) {
		throw std::runtime_error("Item attributes could not round-trip exactly for " + std::to_string(serverId) + ".");
	}
	item->select();
	return item;
}

// Build an undoable replacement without publishing it or changing either input.
// Tile::deepCopy is not const, although it only reads the source tile.
Tile* BuildScenePasteTile(BaseMap& map, Tile& source, Tile* previous, const Position& position) {
	TileLocation* location = map.createTileL(position);
	std::unique_ptr<Tile> copy(source.deepCopy(map));
	copy->setLocation(location);
	if (copy->ground) return copy.release();

	std::unique_ptr<Tile> result(previous ? previous->deepCopy(map) : map.allocator(location));
	result->setLocation(location);
	// Preserve received bottom-to-top order, including always-bottom objects.
	result->items.insert(result->items.end(), copy->items.begin(), copy->items.end());
	copy->items.clear();
	result->setMapFlags(result->getMapFlags() | copy->getMapFlags());
	result->zones.insert(copy->zones.begin(), copy->zones.end());
	if (copy->house_id) result->house_id = copy->house_id;
	if (copy->creature) {
		delete result->creature;
		result->creature = copy->creature;
		copy->creature = nullptr;
	}
	if (copy->spawn) {
		delete result->spawn;
		result->spawn = copy->spawn;
		copy->spawn = nullptr;
	}
	result->update();
	return result.release();
}
} // namespace

CopyBuffer::CopyBuffer() :
	tiles(newd BaseMap()) {
	;
}

BaseMap& CopyBuffer::getBufferMap() {
	ASSERT(tiles);
	return *tiles;
}

CopyBuffer::~CopyBuffer() {
	clear();
}

Position CopyBuffer::getPosition() const {
	ASSERT(tiles);
	return copyPos;
}

void CopyBuffer::clear() {
	delete tiles;
	tiles = nullptr;
	preserveSceneLayout = false;
}

void CopyBuffer::replace(BaseMap* map, const Position& position) {
	clear();
	tiles = map;
	copyPos = position;
}

void CopyBuffer::copy(Editor& editor, int floor) {
	if (editor.selection.size() == 0) {
		g_gui.SetStatusText("No tiles to copy.");
		return;
	}

	clear();
	tiles = newd BaseMap();

	int tile_count = 0;
	int item_count = 0;
	copyPos = Position(0xFFFF, 0xFFFF, floor);

	for (auto it = editor.selection.begin(); it != editor.selection.end(); ++it) {
		++tile_count;

		Tile* tile = *it;
		TileLocation* newlocation = tiles->createTileL(tile->getPosition());
		Tile* copied_tile = tiles->allocator(newlocation);

		if (tile->ground && tile->ground->isSelected()) {
			copied_tile->house_id = tile->house_id;
			copied_tile->setMapFlags(tile->getMapFlags());
			copied_tile->zones = tile->zones;
		}

		ItemVector tile_selection = tile->getSelectedItems();
		for (auto iit = tile_selection.begin(); iit != tile_selection.end(); ++iit) {
			++item_count;
			// Copy items to copybuffer
			copied_tile->addItem((*iit)->deepCopy());
		}

		if (tile->creature && tile->creature->isSelected()) {
			copied_tile->creature = tile->creature->deepCopy();
		}
		if (tile->spawn && tile->spawn->isSelected()) {
			copied_tile->spawn = tile->spawn->deepCopy();
		}

		tiles->setTile(copied_tile);

		if (copied_tile->getX() < copyPos.x) {
			copyPos.x = copied_tile->getX();
		}

		if (copied_tile->getY() < copyPos.y) {
			copyPos.y = copied_tile->getY();
		}
	}

	std::ostringstream ss;
	ss << "Copied " << tile_count << " tile" << (tile_count > 1 ? "s" : "") << " (" << item_count << " item" << (item_count > 1 ? "s" : "") << ")";
	std::string sceneError;
	if (exportAsepriteScene(editor, sceneError)) {
		ss << " - ready to paste in Aseprite";
	} else {
		ss << " - Aseprite export: " << sceneError;
	}
	g_gui.SetStatusText(wxstr(ss.str()));
}

void CopyBuffer::cut(Editor& editor, int floor) {
	if (editor.selection.size() == 0) {
		g_gui.SetStatusText("No tiles to cut.");
		return;
	}

	clear();
	tiles = newd BaseMap();

	int tile_count = 0;
	int item_count = 0;
	copyPos = Position(0xFFFF, 0xFFFF, floor);

	BatchAction* batch = editor.actionQueue->createBatch(ACTION_CUT_TILES);
	Action* action = editor.actionQueue->createAction(batch);

	PositionList tilestoborder;

	for (auto it = editor.selection.begin(); it != editor.selection.end(); ++it) {
		tile_count++;

		Tile* tile = *it;
		Tile* newtile = tile->deepCopy(editor.map);
		Tile* copied_tile = tiles->allocator(tile->getLocation());

		if (tile->ground && tile->ground->isSelected()) {
			copied_tile->house_id = newtile->house_id;
			newtile->house_id = 0;
			copied_tile->zones = tile->zones;
			copied_tile->setMapFlags(tile->getMapFlags());
			newtile->setMapFlags(TILESTATE_NONE);
			newtile->removeZones();
		}

		ItemVector tile_selection = newtile->popSelectedItems();
		for (auto iit = tile_selection.begin(); iit != tile_selection.end(); ++iit) {
			item_count++;
			// Add items to copybuffer
			copied_tile->addItem(*iit);
		}

		if (newtile->creature && newtile->creature->isSelected()) {
			copied_tile->creature = newtile->creature;
			newtile->creature = nullptr;
		}

		if (newtile->spawn && newtile->spawn->isSelected()) {
			copied_tile->spawn = newtile->spawn;
			newtile->spawn = nullptr;
		}

		tiles->setTile(copied_tile->getPosition(), copied_tile);

		if (copied_tile->getX() < copyPos.x) {
			copyPos.x = copied_tile->getX();
		}

		if (copied_tile->getY() < copyPos.y) {
			copyPos.y = copied_tile->getY();
		}

		if (g_settings.getInteger(Config::USE_AUTOMAGIC)) {
			for (int y = -1; y <= 1; y++) {
				for (int x = -1; x <= 1; x++) {
					tilestoborder.push_back(Position(tile->getX() + x, tile->getY() + y, tile->getZ()));
				}
			}
		}
		action->addChange(newd Change(newtile));
	}

	batch->addAndCommitAction(action);

	// Remove duplicates
	tilestoborder.sort();
	tilestoborder.unique();

	if (g_settings.getInteger(Config::USE_AUTOMAGIC)) {
		action = editor.actionQueue->createAction(batch);
		for (auto it = tilestoborder.begin(); it != tilestoborder.end(); ++it) {
			TileLocation* location = editor.map.createTileL(*it);
			if (location->get()) {
				Tile* new_tile = location->get()->deepCopy(editor.map);
				new_tile->borderize(&editor.map);
				new_tile->wallize(&editor.map);
				action->addChange(newd Change(new_tile));
			} else {
				Tile* new_tile = editor.map.allocator(location);
				new_tile->borderize(&editor.map);
				if (new_tile->size()) {
					action->addChange(newd Change(new_tile));
				} else {
					delete new_tile;
				}
			}
		}

		batch->addAndCommitAction(action);
	}

	editor.addBatch(batch);
	std::stringstream ss;
	ss << "Cut out " << tile_count << " tile" << (tile_count > 1 ? "s" : "") << " (" << item_count << " item" << (item_count > 1 ? "s" : "") << ")";
	g_gui.SetStatusText(wxstr(ss.str()));
}

void CopyBuffer::paste(Editor& editor, const Position& toPosition) {
	if (!tiles) {
		return;
	}

	BatchAction* batchAction = editor.actionQueue->createBatch(ACTION_PASTE_TILES);
	Action* action = editor.actionQueue->createAction(batchAction);
	for (MapIterator it = tiles->begin(); it != tiles->end(); ++it) {
		Tile* buffer_tile = (*it)->get();
		Position pos = buffer_tile->getPosition() - copyPos + toPosition;

		if (!pos.isValid()) {
			continue;
		}

		TileLocation* location = editor.map.createTileL(pos);
		Tile* new_dest_tile = nullptr;
		if (preserveSceneLayout) {
			new_dest_tile = BuildScenePasteTile(editor.map, *buffer_tile, location->get(), pos);
		} else {
			Tile* copy_tile = buffer_tile->deepCopy(editor.map);
			Tile* old_dest_tile = location->get();
			copy_tile->setLocation(location);
			if (g_settings.getInteger(Config::MERGE_PASTE) || !copy_tile->ground) {
				new_dest_tile = old_dest_tile ? old_dest_tile->deepCopy(editor.map) : editor.map.allocator(location);
				new_dest_tile->merge(copy_tile);
				delete copy_tile;
			} else {
				new_dest_tile = copy_tile;
			}
		}
		// Imported scenes have no border pass and do not create empty neighbors.
		if (!preserveSceneLayout) {
			editor.map.createTile(pos.x - 1, pos.y - 1, pos.z);
			editor.map.createTile(pos.x, pos.y - 1, pos.z);
			editor.map.createTile(pos.x + 1, pos.y - 1, pos.z);
			editor.map.createTile(pos.x - 1, pos.y, pos.z);
			editor.map.createTile(pos.x + 1, pos.y, pos.z);
			editor.map.createTile(pos.x - 1, pos.y + 1, pos.z);
			editor.map.createTile(pos.x, pos.y + 1, pos.z);
			editor.map.createTile(pos.x + 1, pos.y + 1, pos.z);
		}

		action->addChange(newd Change(new_dest_tile));
	}
	batchAction->addAndCommitAction(action);

	if (!preserveSceneLayout && g_settings.getInteger(Config::USE_AUTOMAGIC) && g_settings.getInteger(Config::BORDERIZE_PASTE)) {
		action = editor.actionQueue->createAction(batchAction);
		TileList borderize_tiles;
		Map& map = editor.map;

		// Go through all modified (selected) tiles (might be slow)
		for (MapIterator it = tiles->begin(); it != tiles->end(); ++it) {
			bool add_me = false; // If this tile is touched
			Position pos = (*it)->getPosition() - copyPos + toPosition;
			if (pos.z < 0 || pos.z >= MAP_LAYERS) {
				continue;
			}
			// Go through all neighbours
			Tile* t;
			t = map.getTile(pos.x - 1, pos.y - 1, pos.z);
			if (t && !t->isSelected()) {
				borderize_tiles.push_back(t);
				add_me = true;
			}
			t = map.getTile(pos.x, pos.y - 1, pos.z);
			if (t && !t->isSelected()) {
				borderize_tiles.push_back(t);
				add_me = true;
			}
			t = map.getTile(pos.x + 1, pos.y - 1, pos.z);
			if (t && !t->isSelected()) {
				borderize_tiles.push_back(t);
				add_me = true;
			}
			t = map.getTile(pos.x - 1, pos.y, pos.z);
			if (t && !t->isSelected()) {
				borderize_tiles.push_back(t);
				add_me = true;
			}
			t = map.getTile(pos.x + 1, pos.y, pos.z);
			if (t && !t->isSelected()) {
				borderize_tiles.push_back(t);
				add_me = true;
			}
			t = map.getTile(pos.x - 1, pos.y + 1, pos.z);
			if (t && !t->isSelected()) {
				borderize_tiles.push_back(t);
				add_me = true;
			}
			t = map.getTile(pos.x, pos.y + 1, pos.z);
			if (t && !t->isSelected()) {
				borderize_tiles.push_back(t);
				add_me = true;
			}
			t = map.getTile(pos.x + 1, pos.y + 1, pos.z);
			if (t && !t->isSelected()) {
				borderize_tiles.push_back(t);
				add_me = true;
			}
			if (add_me) {
				borderize_tiles.push_back(map.getTile(pos));
			}
		}
		// Remove duplicates
		borderize_tiles.sort();
		borderize_tiles.unique();

		for (Tile* tile : borderize_tiles) {
			if (tile) {
				Tile* newTile = tile->deepCopy(editor.map);
				newTile->borderize(&map);

				if (tile->ground && tile->ground->isSelected()) {
					newTile->selectGround();
				}

				newTile->wallize(&map);
				action->addChange(newd Change(newTile));
			}
		}

		// Commit changes to map
		batchAction->addAndCommitAction(action);
	}

	editor.addBatch(batchAction);
}

bool CopyBuffer::canPaste() const {
	return tiles && tiles->size() != 0;
}

bool CopyBuffer::exportAsepriteScene(const Editor& editor, std::string& error) const {
	try {
		if (!canPaste()) throw std::runtime_error("Copy a map selection first.");
		const MapVersion sourceVersion = editor.map.getVersion();
		// OTBM 4 (native enum value 3) retains arbitrary item attribute maps even
		// when the source map uses an older format. All IDs here are server IDs.
		const MapVersion packetVersion(MAP_OTBM_4, sourceVersion.client);
		IOMapOTBM codec(packetVersion);
		SceneJson packet = {{"format", "tibia-aseprite-scene"}, {"version", 1}, {"tileSize", 32},
			{"origin", PositionJson(copyPos)}, {"mapVersion", {{"otbm", packetVersion.otbm}, {"client", packetVersion.client}}},
			{"sourceMapVersion", {{"otbm", sourceVersion.otbm}, {"client", sourceVersion.client}}},
			{"sourceMap", editor.map.getFilename()}, {"tiles", SceneJson::array()}};
		size_t itemCount = 0;
		for (MapIterator it = tiles->begin(); it != tiles->end(); ++it) {
			const Tile* tile = (*it)->get();
			if (!tile) continue;
			SceneJson value = PositionJson(tile->getPosition());
			value["flags"] = tile->getMapFlags();
			value["houseId"] = tile->house_id;
			value["zones"] = tile->zones;
			value["items"] = SceneJson::array();
			if (tile->ground) {
				value["items"].push_back(ExportSceneItem(*tile->ground, *tile, codec, true));
				++itemCount;
			}
			for (const Item* item : tile->items) {
				value["items"].push_back(ExportSceneItem(*item, *tile, codec, false));
				++itemCount;
			}
			// These objects remain metadata while editing item pixels in Aseprite.
			// The importer restores them when the packet is returned unchanged.
			if (const Creature* creature = tile->creature) {
				if (creature->getName().empty()) throw std::runtime_error("Selection contains an unknown creature type.");
				SceneJson alternatives = SceneJson::array();
				for (const auto& alternative : creature->getSpawnAlternatives()) {
					alternatives.push_back({{"name", alternative.name}, {"isNpc", alternative.isNpc}, {"weight", alternative.weight},
						{"hasWeight", alternative.hasWeight}, {"attributes", alternative.attributes}});
				}
				value["creature"] = {{"name", creature->getName()}, {"isNpc", creature->isNpc()}, {"spawnTime", creature->getSpawnTime()},
					{"weight", creature->getWeight()}, {"hasWeight", creature->hasSpawnWeight()}, {"direction", creature->getDirection()},
					{"hasDirection", creature->hasSpawnDirection()}, {"attributes", creature->getSpawnAttributes()},
					{"alternativeKind", static_cast<int>(creature->getAlternativeKind())}, {"alternatives", alternatives}};
				if (creature->hasSpawnSource()) value["creature"]["source"] = PositionJson(creature->getSpawnSource());
			}
			if (const Spawn* spawn = tile->spawn) {
				SceneJson sources = SceneJson::array();
				for (const SpawnAreaKind kind : {SpawnAreaKind::Mixed, SpawnAreaKind::Monsters, SpawnAreaKind::Npcs}) {
					if (spawn->hasSourceKind(kind)) sources.push_back({{"kind", static_cast<int>(kind)}, {"attributes", spawn->getSourceAttributes(kind)}});
				}
				value["spawn"] = {{"size", spawn->getSize()}, {"sources", sources}};
			}
			packet["tiles"].push_back(std::move(value));
			if (itemCount > MaxSceneItems) throw std::runtime_error("Selection exceeds 100000 scene items.");
		}
		const std::string data = packet.dump(2);
		if (data.size() > MaxSceneBytes) throw std::runtime_error("Selection exceeds the 64 MB scene limit.");
		std::filesystem::create_directories(SceneDirectory());
		const auto temporary = SceneDirectory() / L"nexa-scene.json.tmp";
		const auto target = SceneDirectory() / L"nexa-scene.json";
		{
			std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
			output.write(data.data(), data.size());
			output.close();
			if (!output) throw std::runtime_error("Could not write Aseprite scene packet.");
		}
		if (!wxRenameFile(wxString(temporary.wstring()), wxString(target.wstring()), true)) {
			throw std::runtime_error("Could not publish Aseprite scene packet.");
		}
		error.clear();
		return true;
	} catch (const std::exception& exception) {
		error = exception.what();
		// A failed copy must not leave a previous scene looking like the new one.
		std::error_code ignored;
		std::filesystem::remove(SceneDirectory() / L"nexa-scene.json", ignored);
		return false;
	}
}

namespace {
std::unique_ptr<BaseMap> RestoreSceneMap(const SceneJson& packet, ClientVersionID clientVersion, Position& origin) {
		if (packet.at("format") != "tibia-aseprite-scene" || packet.at("version") != 1 || packet.at("tileSize") != 32) {
			throw std::runtime_error("Unsupported Aseprite scene format.");
		}
		const auto& version = packet.at("mapVersion");
		if (version.at("otbm").get<int>() != MAP_OTBM_4 || version.at("client").get<int>() != clientVersion) {
			throw std::runtime_error("Scene and active map must use the same client resources.");
		}
		IOMapOTBM codec(MapVersion(MAP_OTBM_4, version.at("client").get<int>()));
		origin = ReadPosition(packet.at("origin"));
		const auto& tileValues = packet.at("tiles");
		if (!tileValues.is_array() || tileValues.empty() || tileValues.size() > MaxSceneItems) throw std::runtime_error("Scene has no tiles or too many tiles.");
		auto restored = std::make_unique<BaseMap>();
		size_t itemCount = 0;
		for (const auto& value : tileValues) {
			const Position position = ReadPosition(value);
			if (restored->getTile(position)) throw std::runtime_error("Scene contains duplicate tile coordinates.");
			Tile* tile = restored->allocator(restored->createTileL(position));
			restored->setTile(tile);
			tile->setMapFlags(value.value("flags", uint32_t{0}));
			tile->house_id = value.value("houseId", uint32_t{0});
			tile->zones = value.value("zones", std::set<unsigned int>{});
			const auto& itemValues = value.at("items");
			if (!itemValues.is_array()) throw std::runtime_error("Scene tile items must be an array.");
			for (const auto& itemValue : itemValues) {
				if (++itemCount > MaxSceneItems) throw std::runtime_error("Scene exceeds 100000 items.");
				auto item = ImportSceneItem(itemValue, codec);
				if (itemValue.value("ground", false)) {
					if (tile->ground) throw std::runtime_error("Scene tile has more than one ground.");
					tile->ground = item.release();
				} else {
					tile->items.push_back(item.release());
				}
			}
			if (value.contains("creature")) {
				const auto& c = value.at("creature");
				auto creature = std::make_unique<Creature>(c.at("name").get<std::string>());
				creature->setSpawnType(c.at("isNpc").get<bool>());
				creature->setSpawnTime(c.at("spawnTime").get<int>());
				creature->setSpawnWeight(c.at("weight").get<uint32_t>(), c.at("hasWeight").get<bool>());
				const int direction = c.at("direction").get<int>();
				const int alternativeKind = c.at("alternativeKind").get<int>();
				if (direction < NORTH || direction > WEST || alternativeKind < 0 || alternativeKind > 2) throw std::runtime_error("Invalid creature metadata.");
				creature->setSpawnDirection(static_cast<Direction>(direction), c.at("hasDirection").get<bool>());
				creature->setAlternativeKind(static_cast<SpawnAlternativeKind>(alternativeKind));
				creature->setSpawnAttributes(c.at("attributes").get<SpawnAttributeMap>());
				if (c.contains("source")) creature->setSpawnSource(ReadPosition(c.at("source")));
				for (const auto& a : c.at("alternatives")) {
					SpawnVariantData alternative;
					alternative.name = a.at("name").get<std::string>();
					alternative.isNpc = a.at("isNpc").get<bool>();
					alternative.weight = a.at("weight").get<uint32_t>();
					alternative.hasWeight = a.at("hasWeight").get<bool>();
					alternative.attributes = a.at("attributes").get<SpawnAttributeMap>();
					creature->addSpawnAlternative(alternative);
				}
				creature->select();
				tile->creature = creature.release();
			}
			if (value.contains("spawn")) {
				const auto& s = value.at("spawn");
				const int radius = s.at("size").get<int>();
				if (radius < 0 || radius > 255) throw std::runtime_error("Invalid spawn radius.");
				auto spawn = std::make_unique<Spawn>(radius);
				for (const auto& source : s.at("sources")) {
					const int kind = source.at("kind").get<int>();
					if (kind < 0 || kind > 2) throw std::runtime_error("Invalid spawn source kind.");
					spawn->setSourceAttributes(static_cast<SpawnAreaKind>(kind), source.at("attributes").get<SpawnAttributeMap>());
				}
				spawn->select();
				tile->spawn = spawn.release();
			}
			tile->update();
		}
	return restored;
}
} // namespace

bool CopyBuffer::importAsepriteScene(const Editor& editor, std::string& error) {
	try {
		const auto path = SceneDirectory() / L"aseprite-scene.json";
		std::error_code ec;
		const auto size = std::filesystem::file_size(path, ec);
		if (ec || size == 0 || size > MaxSceneBytes) throw std::runtime_error("No valid aseprite-scene.json. Copy a scene from Aseprite first.");
		std::ifstream input(path, std::ios::binary);
		if (!input) throw std::runtime_error("Could not open the Aseprite scene packet.");
		SceneJson packet;
		input >> packet;
		Position origin;
		auto restored = RestoreSceneMap(packet, editor.map.getVersion().client, origin);
		// Replacement is deliberately last: failures retain the old copy buffer.
		replace(restored.release(), origin);
		preserveSceneLayout = true;
		error.clear();
		return true;
	} catch (const std::exception& exception) {
		error = exception.what();
		return false;
	}
}

bool CopyBuffer::selfTestAsepriteScene(const std::string& itemsPath, const std::string& reportPath) {
	SceneJson report = {{"success", false}, {"tests", SceneJson::array()}};
	try {
		wxString error;
		wxArrayString warnings;
		// This isolated process has no selected client profile or GUI. The real
		// OTB header is still parsed; only the GUI profile comparison is bypassed.
		g_settings.setInteger(Config::CHECK_SIGNATURES, 0);
		if (!g_items.loadFromOtb(FileName(wxstr(itemsPath)), error, warnings)) throw std::runtime_error(nstr(error));
		uint16_t plainId = 0, containerId = 0, stackId = 0, fluidId = 0, groundId = 0, bottomId = 0;
		for (int id = 100; id <= g_items.getMaxID(); ++id) {
			if (!g_items.typeExists(id)) continue;
			const ItemType& type = g_items[id];
			if (!plainId && type.type == ITEM_TYPE_NONE && !type.stackable && !type.isGroundTile() && !type.isFluidContainer() && !type.isSplash()) plainId = static_cast<uint16_t>(id);
			if (!containerId && type.isContainer()) containerId = static_cast<uint16_t>(id);
			if (!stackId && type.stackable) stackId = static_cast<uint16_t>(id);
			if (!fluidId && type.isFluidContainer()) fluidId = static_cast<uint16_t>(id);
			if (!groundId && type.isGroundTile()) groundId = static_cast<uint16_t>(id);
			if (!bottomId && type.alwaysOnBottom && !type.isGroundTile()) bottomId = static_cast<uint16_t>(id);
		}
		if (!plainId || !containerId || !stackId || !fluidId) throw std::runtime_error("Self-test requires plain, container, stackable and fluid item types.");
		IOMapOTBM codec(MapVersion(MAP_OTBM_4, CLIENT_VERSION_860));
		BaseMap map;
		const Position position(32000, 32000, 7);
		Tile* tile = map.allocator(map.createTileL(position));
		map.setTile(tile);
		std::vector<std::pair<std::string, std::unique_ptr<Item>>> samples;
		auto plain = std::unique_ptr<Item>(Item::Create(plainId));
		plain->setActionID(54321);
		plain->setUniqueID(12345);
		plain->setText("Aseprite bridge: \"quotes\", newline\n and escaped bytes \xfd\xfe\xff");
		plain->setDescription("Native OTBM attribute preservation");
		plain->setAttribute("bridge.integer", int32_t{-4567});
		plain->setAttribute("bridge.decimal", 3.125);
		plain->setAttribute("bridge.boolean", true);
		plain->setAttribute("bridge.string", std::string("nested custom value"));
		samples.emplace_back("custom_attributes", std::move(plain));
		samples.emplace_back("stack_subtype", std::unique_ptr<Item>(Item::Create(stackId, 57)));
		samples.emplace_back("fluid_subtype", std::unique_ptr<Item>(Item::Create(fluidId, 7)));
		auto container = std::make_unique<Container>(containerId);
		container->setActionID(4321);
		auto nested = std::make_unique<Container>(containerId);
		nested->setText("nested container");
		nested->getVector().push_back(Item::Create(stackId, 23));
		container->getVector().push_back(nested.release());
		container->getVector().push_back(Item::Create(plainId));
		samples.emplace_back("nested_container", std::move(container));
		// Deliberately use a plain ItemType for these three: the native loader
		// must infer dynamic classes from persisted special attributes.
		auto teleport = std::make_unique<Teleport>(plainId);
		teleport->setDestination(Position(32123, 32456, 6));
		samples.emplace_back("teleport_destination", std::move(teleport));
		auto door = std::make_unique<Door>(plainId);
		door->setDoorID(67);
		samples.emplace_back("house_door_id", std::move(door));
		auto depot = std::make_unique<Depot>(plainId);
		depot->setDepotID(2345);
		samples.emplace_back("depot_id", std::move(depot));
		SceneJson fixture = {{"format", "tibia-aseprite-scene"}, {"version", 1}, {"tileSize", 32},
			{"origin", PositionJson(position)}, {"mapVersion", {{"otbm", MAP_OTBM_4}, {"client", CLIENT_VERSION_860}}}, {"tiles", SceneJson::array()}};
		int index = 0;
		for (const auto& [name, item] : samples) {
			const SceneJson encoded = SceneJson::parse(ExportSceneItem(*item, *tile, codec, false).dump());
			auto restored = ImportSceneItem(encoded, codec);
			if (item->hasSubtype() && restored->getSubtype() != item->getSubtype()) throw std::runtime_error("Subtype mismatch in " + name);
			if (name == "nested_container" && (!dynamic_cast<Container*>(restored.get()) || static_cast<Container*>(restored.get())->getItemCount() != 2)) throw std::runtime_error("Nested container type was lost.");
			if (name == "teleport_destination" && (!dynamic_cast<Teleport*>(restored.get()) || static_cast<Teleport*>(restored.get())->getDestination() != Position(32123, 32456, 6))) throw std::runtime_error("Teleport destination was lost.");
			report["tests"].push_back({{"name", name}, {"serverId", item->getID()}, {"clientId", item->getClientID()}, {"nativeBytes", encoded.at("otbmHex").get<std::string>().size() / 2}, {"passed", true}});
			SceneJson tileValue = PositionJson(Position(position.x + index % 4, position.y + index / 4, position.z - index / 4));
			tileValue["flags"] = index == 0 ? 1 : 0;
			tileValue["houseId"] = index == 0 ? 42 : 0;
			tileValue["zones"] = SceneJson::array({17, 23});
			tileValue["items"] = SceneJson::array({encoded});
			fixture["tiles"].push_back(std::move(tileValue));
			++index;
		}
		Position restoredOrigin;
		auto restoredMap = RestoreSceneMap(SceneJson::parse(fixture.dump()), CLIENT_VERSION_860, restoredOrigin);
		if (restoredOrigin != position) throw std::runtime_error("Scene origin was lost.");
		index = 0;
		for (const auto& [name, item] : samples) {
			const Position expected(position.x + index % 4, position.y + index / 4, position.z - index / 4);
			const Tile* restoredTile = restoredMap->getTile(expected);
			if (!restoredTile || restoredTile->items.size() != 1 || restoredTile->items[0]->getID() != item->getID() || !restoredTile->items[0]->isSelected() || restoredTile->zones != std::set<unsigned int>({17, 23})) {
				throw std::runtime_error("Scene positions, floors, zones or selection changed.");
			}
			if (index == 0 && (restoredTile->getMapFlags() != 1 || restoredTile->house_id != 42)) throw std::runtime_error("Tile flags or house ID was lost.");
			++index;
		}
		report["tests"].push_back({{"name", "scene_positions_floors_flags_zones_selection"}, {"tiles", samples.size()}, {"passed", true}});
		{
			if (!groundId || !bottomId) throw std::runtime_error("Paste tests require ground and always-bottom item types.");
			BaseMap sourceMap, destinationMap;
			const Position sourcePos(31000, 31000, 7), destinationPos(33000, 33000, 6), emptyPos(33010, 33010, 6);
			Tile* source = sourceMap.allocator(sourceMap.createTileL(sourcePos));
			sourceMap.setTile(source);
			Tile* previous = destinationMap.allocator(destinationMap.createTileL(destinationPos));
			destinationMap.setTile(previous);
			previous->ground = Item::Create(groundId);
			previous->items.push_back(Item::Create(fluidId, 5));
			previous->items[0]->setActionID(2001);
			previous->setMapFlags(1);
			previous->house_id = 77;
			previous->zones = {1, 2};
			previous->spawn = newd Spawn(2);
			for (const uint16_t id : {plainId, bottomId, stackId}) {
				Item* item = Item::Create(id, 9);
				item->setActionID(static_cast<uint16_t>(1001 + source->items.size()));
				source->items.push_back(item);
			}
			source->setMapFlags(4);
			source->house_id = 88;
			source->zones = {2, 3};
			source->spawn = newd Spawn(7);
			g_settings.setInteger(Config::MERGE_PASTE, 1);
			g_settings.setInteger(Config::USE_AUTOMAGIC, 1);
			g_settings.setInteger(Config::BORDERIZE_PASTE, 1);
			std::unique_ptr<Tile> merged(BuildScenePasteTile(destinationMap, *source, previous, destinationPos));
			if (merged->getPosition() != destinationPos || merged->ground == previous->ground || !merged->ground || merged->ground->getID() != groundId || merged->items.size() != 4 || merged->getMapFlags() != 5 || merged->house_id != 88 || merged->zones != std::set<unsigned int>({1, 2, 3}) || !merged->spawn || merged->spawn == source->spawn || merged->spawn->getSize() != 7) {
				throw std::runtime_error("Item-only scene paste lost ground, attributes, zones or independent ownership.");
			}
			for (size_t i = 0; i < merged->items.size(); ++i) {
				const Item* expected = i == 0 ? previous->items[0] : source->items[i - 1];
				if (merged->items[i] == expected || merged->items[i]->getID() != expected->getID() || merged->items[i]->getActionID() != expected->getActionID()) throw std::runtime_error("Scene paste reordered or shared item objects.");
			}
			if (previous->items.size() != 1 || previous->getMapFlags() != 1 || previous->house_id != 77 || previous->zones != std::set<unsigned int>({1, 2}) || previous->spawn->getSize() != 2 || source->items.size() != 3 || source->getMapFlags() != 4 || source->spawn->getSize() != 7 || source->ground) {
				throw std::runtime_error("Scene paste changed its input tiles.");
			}
			std::unique_ptr<Tile> fresh(BuildScenePasteTile(destinationMap, *source, nullptr, emptyPos));
			if (fresh->ground || fresh->items.size() != 3 || fresh->getPosition() != emptyPos || fresh->zones != source->zones) throw std::runtime_error("Item-only paste onto an empty tile failed.");
			source->ground = Item::Create(groundId);
			std::unique_ptr<Tile> replacement(BuildScenePasteTile(destinationMap, *source, previous, destinationPos));
			if (!replacement->ground || replacement->ground == source->ground || replacement->items.size() != source->items.size() || replacement->getMapFlags() != 4 || replacement->house_id != 88 || replacement->zones != std::set<unsigned int>({2, 3}) || replacement->items[0]->getActionID() != 1001) {
				throw std::runtime_error("Ground-containing scene did not replace the complete destination tile.");
			}
			if (destinationMap.getTile(destinationPos) != previous || destinationMap.getTile(emptyPos) || destinationMap.size() != 1 || sourceMap.getTile(sourcePos) != source || previous->items[0]->getActionID() != 2001 || source->items[0]->getActionID() != 1001) throw std::runtime_error("Scene tile construction published changes before the undo action.");
			for (int y = -1; y <= 1; ++y) for (int x = -1; x <= 1; ++x) {
				if ((x || y) && destinationMap.getTile(destinationPos + Position(x, y, 0))) throw std::runtime_error("Scene paste created neighboring tiles.");
			}
			report["tests"].push_back({{"name", "scene_paste_item_order_merge_flags_zones_ownership"}, {"passed", true}});
			report["tests"].push_back({{"name", "scene_paste_ground_replacement_and_empty_destination"}, {"passed", true}});
			report["tests"].push_back({{"name", "scene_paste_inputs_unchanged_no_neighbors_before_undo_action"}, {"passed", true}});
		}
		const auto good = ExportSceneItem(*samples.front().second, *tile, codec, false);
		int rejected = 0;
		for (const std::string corrupt : {std::string("fe0601"), std::string("fe060100ff00"), std::string("fe060100fd")}) {
			auto bad = good;
			bad["otbmHex"] = corrupt;
			try { ImportSceneItem(bad, codec); } catch (const std::exception&) { ++rejected; }
		}
		if (rejected != 3) throw std::runtime_error("Corrupted native payload was accepted.");
		report["tests"].push_back({{"name", "corrupt_payload_rejection"}, {"cases", rejected}, {"passed", true}});
		const auto fixturePath = std::filesystem::path(reportPath).parent_path() / "native-fixture-scene.json";
		std::ofstream fixtureOutput(fixturePath, std::ios::binary | std::ios::trunc);
		fixtureOutput << fixture.dump(2);
		if (!fixtureOutput) throw std::runtime_error("Could not write native test fixture.");
		report["fixture"] = fixturePath.string();
		report["success"] = true;
	} catch (const std::exception& exception) {
		report["error"] = exception.what();
	}
	std::ofstream output(std::filesystem::path(reportPath), std::ios::binary | std::ios::trunc);
	output << report.dump(2);
	return output.good() && report.at("success").get<bool>();
}

bool CopyBuffer::validateAsepriteScene(const std::string& itemsPath, const std::string& packetPath, const std::string& reportPath) {
	SceneJson report = {{"success", false}};
	try {
		g_settings.setInteger(Config::CHECK_SIGNATURES, 0);
		wxString error;
		wxArrayString warnings;
		if (!g_items.loadFromOtb(FileName(wxstr(itemsPath)), error, warnings)) throw std::runtime_error(nstr(error));
		const auto path = std::filesystem::path(packetPath);
		const auto size = std::filesystem::file_size(path);
		if (size == 0 || size > MaxSceneBytes) throw std::runtime_error("Invalid scene file size.");
		std::ifstream input(path, std::ios::binary);
		SceneJson packet;
		input >> packet;
		Position origin;
		const int clientVersion = packet.at("mapVersion").at("client").get<int>();
		auto restored = RestoreSceneMap(packet, clientVersion, origin);
		IOMapOTBM codec(MapVersion(MAP_OTBM_4, clientVersion));
		report["origin"] = PositionJson(origin);
		report["tiles"] = SceneJson::array();
		size_t itemCount = 0;
		for (MapIterator it = restored->begin(); it != restored->end(); ++it) {
			const Tile* tile = (*it)->get();
			if (!tile) continue;
			SceneJson value = PositionJson(tile->getPosition());
			value["flags"] = tile->getMapFlags();
			value["houseId"] = tile->house_id;
			value["zones"] = tile->zones;
			value["items"] = SceneJson::array();
			if (tile->ground) {
				value["items"].push_back(ExportSceneItem(*tile->ground, *tile, codec, true));
				++itemCount;
			}
			for (const Item* item : tile->items) {
				value["items"].push_back(ExportSceneItem(*item, *tile, codec, false));
				++itemCount;
			}
			report["tiles"].push_back(std::move(value));
		}
		report["tileCount"] = report["tiles"].size();
		report["itemCount"] = itemCount;
		report["success"] = true;
	} catch (const std::exception& exception) {
		report["error"] = exception.what();
	}
	std::ofstream output(std::filesystem::path(reportPath), std::ios::binary | std::ios::trunc);
	output << report.dump(2);
	return output.good() && report.at("success").get<bool>();
}
