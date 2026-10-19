/*
 * Batch Child Features – QField plugin
 *
 * Select several features in QField's feature list (multi-selection), open the
 * list menu (⋮) and choose "Add child to selection". The child form opens once
 * for the first selected parent; after saving, one child feature is created for
 * every other selected parent.
 *
 * Copy rule: only the fields the user edited in the form are copied to the
 * other children. Every other field gets its own default value per parent,
 * evaluated with that parent as @parent (exactly like QField's relation editor
 * does), so defaults such as UUIDs, "last value of this parent" aggregates or
 * parent-derived values stay correct for each parent.
 *
 * Optionally, each parent is saved once afterwards so that "apply on update"
 * default values (e.g. relation_aggregate() counters or "next inspection" dates)
 * are recalculated.
 *
 * Requires QField >= 4.0. Only geometryless child layers are supported.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtCore

import org.qfield
import org.qgis
import Theme

Item {
  id: plugin

  // ------------------------------------------------------------------ QField objects

  property var mainWindow: iface.mainWindow()
  property var featureForm: iface.findItemByObjectName("featureForm")
  property var featureListMenu: iface.findItemByObjectName("featureListMenu")
  property var overlayDrawer: iface.findItemByObjectName("overlayFeatureFormDrawer")
  property var dashBoard: iface.findItemByObjectName("dashBoard")
  property var appScopes: iface.findItemByObjectName("appScopesGenerator")

  property var listModel: featureForm ? featureForm.model : null
  readonly property var selectedLayer: listModel ? listModel.selectedLayer : null
  readonly property int selectedCount: listModel ? listModel.selectedCount : 0

  // Child relations usable for the currently selected layer
  property var childRelations: []
  onSelectedLayerChanged: childRelations = childRelationsOf(selectedLayer)

  property bool busy: false
  property var job: null

  Settings {
    id: settings
    category: "qfield-batch-children"
    property bool refreshParents: true
  }

  // ------------------------------------------------------------------ Menu entry

  MenuSeparator {
    id: menuSeparator
    visible: batchMenuItem.visible
    height: visible ? undefined : 0
  }

  MenuItem {
    id: batchMenuItem
    text: qsTr("Add child to selection (%1)").arg(plugin.selectedCount)
    icon.source: Theme.getThemeVectorIcon("ic_add_white_24dp")
    font: Theme.defaultFont
    leftPadding: Theme.menuItemLeftPadding
    visible: plugin.selectedCount > 0 && plugin.childRelations.length > 0
    height: visible ? 48 : 0
    enabled: visible && !plugin.busy

    onTriggered: {
      if (plugin.childRelations.length === 1) {
        Qt.callLater(plugin.start, plugin.childRelations[0]);
      } else {
        Qt.callLater(relationChooser.open);
      }
    }
  }

  // ------------------------------------------------------------------ Relation chooser

  Menu {
    id: relationChooser
    parent: plugin.mainWindow.contentItem
    title: qsTr("Add child to selection")
    x: (parent.width - width) / 2
    y: (parent.height - height) / 2

    Instantiator {
      model: plugin.childRelations
      delegate: MenuItem {
        text: modelData.label
        font: Theme.defaultFont
        height: 48
        onTriggered: Qt.callLater(plugin.start, modelData)
      }
      onObjectAdded: (index, object) => relationChooser.insertItem(index, object)
      onObjectRemoved: (index, object) => relationChooser.removeItem(object)
    }
  }

  // ------------------------------------------------------------------ Settings dialog

  Dialog {
    id: settingsDialog
    parent: plugin.mainWindow.contentItem
    title: qsTr("Batch Child Features")
    modal: true
    standardButtons: Dialog.Close
    x: (parent.width - width) / 2
    y: (parent.height - height) / 2
    width: Math.min(parent.width - 32, 420)

    ColumnLayout {
      anchors.fill: parent

      CheckBox {
        Layout.fillWidth: true
        text: qsTr("Save parent features afterwards")
        font: Theme.defaultFont
        checked: settings.refreshParents
        onToggled: settings.refreshParents = checked
      }

      Label {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        font: Theme.tipFont
        color: Theme.secondaryTextColor
        text: qsTr("Recalculates the parents' \"apply on update\" default values, e.g. relation_aggregate() counters or next inspection dates.")
      }
    }
  }

  function configure() {
    settingsDialog.open();
  }

  // ------------------------------------------------------------------ Helper models

  // Reads the parent layer's form configuration to discover child relations
  FeatureModel {
    id: probeModel
    project: qgisProject
  }

  AttributeFormModel {
    id: probeForm
    featureModel: probeModel
  }

  // Creates the copies
  FeatureModel {
    id: copyModel
    project: qgisProject
  }

  AttributeFormModel {
    id: copyForm
    featureModel: copyModel
  }

  // Saves the parents afterwards
  FeatureModel {
    id: parentModel
    project: qgisProject
  }

  // ------------------------------------------------------------------ Form signals

  Connections {
    target: plugin.overlayDrawer ? plugin.overlayDrawer.featureForm : null
    enabled: plugin.job !== null

    function onValueChanged(field, oldValue, newValue) {
      if (plugin.job.phase === "form") {
        plugin.job.edited[field.name] = true;
      }
    }

    function onConfirmed() {
      const job = plugin.job;
      if (job.phase !== "form")
        return;
      // confirmed is only emitted after the feature was saved successfully
      const first = plugin.overlayDrawer.featureModel.feature;
      for (const name in job.edited) {
        job.values[name] = first.attribute(name);
      }
      job.phase = "copy";
    }

    function onCancelled() {
      if (plugin.job.phase === "form")
        plugin.job.phase = "cancel";
    }
  }

  Connections {
    target: plugin.overlayDrawer
    enabled: plugin.job !== null

    // QField's own onClosed handler runs first and may still emit confirmed()
    function onClosed() {
      const job = plugin.job;
      if (job.phase === "form")
        job.phase = "cancel";
      plugin.restoreOverlay(job);
      if (job.phase === "copy") {
        Qt.callLater(plugin.createCopies);
      } else {
        plugin.finish();
      }
    }
  }

  // ------------------------------------------------------------------ Lifecycle

  Component.onCompleted: {
    if (!featureListMenu || !overlayDrawer || !featureForm || !dashBoard) {
      iface.logMessage("Batch Child Features: incompatible QField version (QField >= 4.0 required)");
      return;
    }
    copyModel.appExpressionContextScopesGenerator = appScopes;
    featureListMenu.addItem(menuSeparator);
    featureListMenu.addItem(batchMenuItem);
  }

  Component.onDestruction: {
    if (featureListMenu) {
      for (const item of [batchMenuItem, menuSeparator]) {
        try {
          featureListMenu.removeItem(item);
        } catch (e) {}
      }
    }
  }

  // ------------------------------------------------------------------ Relation discovery

  // Child relations shown in the parent layer's form (QField adds all of them
  // for auto-generated forms), restricted to what the batch flow can handle.
  function childRelationsOf(layer) {
    if (!layer)
      return [];
    const found = [];
    const seen = {};
    probeModel.currentLayer = layer;
    collectRelations(layer, undefined, found, seen);
    probeModel.currentLayer = null;
    return found;
  }

  function collectRelations(layer, parentIndex, found, seen) {
    const rows = parentIndex === undefined ? probeForm.rowCount() : probeForm.rowCount(parentIndex);
    for (let row = 0; row < rows; row++) {
      const idx = parentIndex === undefined ? probeForm.index(row, 0) : probeForm.index(row, 0, parentIndex);
      if (probeForm.data(idx, AttributeFormModel.ElementType) === "relation") {
        const entry = relationEntry(layer, probeForm.data(idx, AttributeFormModel.RelationId), probeForm.data(idx, AttributeFormModel.NmRelationId), probeForm.data(idx, AttributeFormModel.RelationEditorWidgetConfig));
        if (entry && !seen[entry.id]) {
          seen[entry.id] = true;
          found.push(entry);
        }
      }
      if (probeForm.rowCount(idx) > 0) {
        collectRelations(layer, idx, found, seen);
      }
    }
  }

  function relationEntry(layer, relationId, nmRelationId, config) {
    if (!relationId || nmRelationId)
      return null; // many-to-many relations are not supported
    const relation = qgisProject.relationManager.relation(relationId);
    if (!relation.isValid || relation.referencedLayer !== layer)
      return null;
    const child = relation.referencingLayer;
    if (!child || child.geometryType() !== Qgis.GeometryType.Null)
      return null; // spatial children would need a geometry per copy
    if (child.readOnly || LayerUtils.isFeatureAdditionLocked(child))
      return null;
    if (!addButtonAllowed(config))
      return null;
    return {
      "id": relationId,
      "relation": relation,
      "childLayer": child,
      "orderingField": config && config["ordering_field"] ? config["ordering_field"] : "",
      "label": relation.name && relation.name !== child.name ? relation.name + " (" + child.name + ")" : child.name
    };
  }

  // Same rule as QField's relation editor for the "add child" button
  function addButtonAllowed(config) {
    const buttons = config ? config["buttons"] : undefined;
    if (buttons === undefined || buttons === "AllButtons")
      return true;
    if (buttons === "NoButton")
      return false;
    return String(buttons).split("|").indexOf("AddChildFeature") >= 0;
  }

  // ------------------------------------------------------------------ Batch flow

  function start(entry) {
    if (busy)
      return;
    if (overlayDrawer.opened) {
      toast(qsTr("Finish the open form first"), "warning");
      return;
    }

    const selected = listModel.selectedFeatures;
    const parents = [];
    for (let i = 0; i < selected.length; i++) {
      parents.push(selected[i]);
    }
    if (parents.length === 0 || listModel.selectedLayer !== entry.relation.referencedLayer) {
      toast(qsTr("No features selected"), "warning");
      return;
    }

    const fm = overlayDrawer.featureModel;
    const form = overlayDrawer.featureForm;

    busy = true;
    job = {
      "entry": entry,
      "parentLayer": entry.relation.referencedLayer,
      "parents": parents,
      "edited": {},
      "values": {},
      "phase": "form",
      "origRelation": fm.linkedRelation,
      "origParent": fm.linkedParentFeature,
      "origOrderingField": fm.linkedRelationOrderingField
    };

    // Same preparation as QField's relation editor, for the first parent.
    // Setting currentLayer breaks its binding to dashBoard.activeLayer; restoreOverlay() rebinds it.
    fm.currentLayer = entry.childLayer;
    prepareChild(fm, entry, parents[0]);
    form.model.applyParentDefaultValues();

    form.featureCreated = false;
    overlayDrawer.state = "Add";
    overlayDrawer.open();
    if (parents.length > 1) {
      toast(qsTr("Form applies to %1 features – edited fields are copied to all").arg(parents.length));
    }
  }

  function createCopies() {
    const job = plugin.job;
    const entry = job.entry;
    let created = 1;
    let failed = 0;

    if (job.parents.length > 1) {
      copyModel.currentLayer = entry.childLayer;
      for (let i = 1; i < job.parents.length; i++) {
        prepareChild(copyModel, entry, job.parents[i]);
        copyForm.applyParentDefaultValues();
        for (const name in job.values) {
          copyForm.changeAttribute(name, job.values[name]);
        }
        if (copyModel.create()) {
          created++;
        } else {
          failed++;
        }
      }
      // An invalid relation clears the model's linked field indexes
      copyModel.linkedRelation = job.origRelation;
      copyModel.linkedParentFeature = job.origParent;
      copyModel.currentLayer = null;
    }

    if (settings.refreshParents && !job.parentLayer.readOnly) {
      refreshParents(job.parentLayer, job.parents);
    }

    if (failed === 0) {
      toast(qsTr("%1 child features added to %2").arg(created).arg(entry.childLayer.name));
    } else {
      toast(qsTr("%1 child features added, %2 failed").arg(created).arg(failed), "error");
    }
    finish();
  }

  // Save each parent once so "apply on update" defaults are recalculated
  // (only changed attributes are written)
  function refreshParents(layer, parents) {
    parentModel.currentLayer = layer;
    for (const parentFeature of parents) {
      const it = LayerUtils.createFeatureIteratorFromExpression(layer, "$id = " + parentFeature.id);
      if (it.hasNext()) {
        parentModel.feature = it.next();
        parentModel.save();
      }
      it.close();
    }
    parentModel.currentLayer = null;
  }

  // ------------------------------------------------------------------ Helpers

  // Order matters: feature -> parent -> relation (fills the foreign key and
  // keeps it through the reset) -> reset (evaluates defaults with @parent)
  function prepareChild(model, entry, parentFeature) {
    model.feature = FeatureUtils.createFeature(entry.childLayer);
    model.linkedParentFeature = parentFeature;
    model.linkedRelation = entry.relation;
    model.linkedRelationOrderingField = entry.orderingField;
    model.resetAttributes();
  }

  function restoreOverlay(job) {
    const fm = overlayDrawer.featureModel;
    fm.linkedRelation = job.origRelation;
    fm.linkedParentFeature = job.origParent;
    fm.linkedRelationOrderingField = job.origOrderingField;
    fm.currentLayer = Qt.binding(function () {
      return dashBoard.activeLayer;
    });
  }

  function finish() {
    job = null;
    busy = false;
  }

  function toast(message, type) {
    mainWindow.displayToast(message, type === undefined ? "info" : type);
  }
}
