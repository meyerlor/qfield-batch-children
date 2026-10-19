# Batch Child Features – QField plugin

Add a child feature to **many parent features at once** in [QField](https://qfield.org).

Typical use: a tree inspector walks a row of 30 trees, all fine. Instead of opening
every tree and adding an inspection record 30 times, they select the trees, fill in
the inspection form **once**, and the plugin creates one inspection per tree.

## Usage

1. Identify features on the map, long-press one in the feature list to start
   multi-selection and tick all parent features.
2. Open the list menu (**⋮**) and choose **Add child to selection (n)**.
   If the layer has more than one child relation, pick the relation.
3. The child form opens for the first selected feature. Fill it in and save.
4. The plugin creates the same child for every other selected feature and reports
   how many were added. The selection stays, so you can add another kind of child
   right away.

## What gets copied

- **Fields you edited in the form** are copied to every child.
- **Every other field** gets its own default value for each parent. Defaults are
  evaluated with that parent as `@parent`, exactly as QField's relation editor does.
  UUIDs, "take the last value of this parent's previous record" aggregates and
  values derived from the parent therefore stay correct for each parent.
- The foreign key is set from the relation; ordering fields of ordered relation
  editors are filled per parent.

## Parent refresh (optional)

Parents often carry "apply on update" default values that depend on their children,
e.g. `relation_aggregate()` counters or a next inspection date. They are only
recalculated when the parent itself is saved. By default the plugin saves each
selected parent once afterwards; only attributes whose value actually changes are
written. Turn this off in QField's plugin settings (the plugin's configure button).

## Which relations are offered

Child relations shown in the parent layer's attribute form (QField includes all of
them in auto-generated forms), where:

- the child layer has **no geometry**,
- the relation is a plain one-to-many relation (not many-to-many),
- the relation editor allows adding children (`AddChildFeature` button),
- the child layer is editable.

## Installation

Requires **QField 4.0 or newer**.

In QField: *Settings → Plugins → Install plugin from URL* and paste the zip URL of
the [latest release](https://github.com/meyerlor/qfield-batch-children/releases/latest).

Works offline and with QFieldCloud: the child features are created through QField's
regular editing path and synchronise like manually entered ones.

## Limitations

- Child layers with geometry are not offered (each copy would need its own geometry).
- Many-to-many relations are not supported.
- The children are created in one go after the form is saved; with very large
  selections (hundreds of features) QField is busy for a moment.

## Development

The plugin is a single `main.qml`. Translations live in `i18n/*.ts` and are compiled
to `main_<lang>.qm` by the release workflow. To release, push a tag such as `v1.0.0`;
the workflow builds the zip and publishes a GitHub release.

## License

GPL-2.0-or-later. Not affiliated with OPENGIS.ch.
