class_name BrowserCatalogue
extends RefCounted

## Everything the Add Node browser can show, from every place the editor keeps things.
##
## Two providers today — the core's node registry and the editor's example shelf — and
## the whole point of the file is that adding a third is adding a provider rather than
## teaching the browser about a new shape. Each provider's only job is to answer in
## `BrowserItem`s; after that there is one pipeline: scope by category, match, group,
## draw.

const DeviceBlurbs := preload("res://device_blurbs.gd")


## `addable` is the editor's own reading of the registry — the type names a person can
## actually add, with the seams collapsed to their terminals. Passed in rather than
## worked out here: it is the editor's rule about its own graph, and this file has no
## business having an opinion about it.
static func build(registry: Dictionary, addable: PackedStringArray,
		examples: Dictionary) -> Array:
	var items: Array = []
	for type_name in addable:
		items.append(BrowserItem.from_node(str(type_name),
			registry.get(type_name, {})))
	for label in examples:
		items.append(BrowserItem.from_device(str(label),
			str(DeviceBlurbs.blurb(str(label)))))
	return items


## The Examples shelf as a reader meets it: every device that is an example, in the
## shelf's own groups and order — the synths, the worked patches, sfxr, then the banks
## the rail also names. One structure for the browser's Examples row and the
## hamburger's Open example… menu, so the two doors cannot show different shelves.
## Each entry is {"name": group, "items": [BrowserItem, ...]}.
static func shelf(examples: Dictionary) -> Array:
	var groups: Array = []
	var by_name := {}
	for label in examples:
		var item := BrowserItem.from_device(str(label), str(DeviceBlurbs.blurb(str(label))))
		if not item.shelves.has("Examples"):
			continue
		if not by_name.has(item.group):
			by_name[item.group] = {"name": item.group, "items": []}
			groups.append(by_name[item.group])
		(by_name[item.group]["items"] as Array).append(item)
	return groups
