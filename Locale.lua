-- HolyOrders — localization
-- The English text is the key; untranslated keys fall through unchanged.

local HO = HolyOrders

local L = setmetatable({}, {
	__index = function(_, key)
		return key
	end,
})
HO.L = L

if GetLocale() ~= "deDE" then
	return
end

-- options
L["HolyOrders — Options"] = "HolyOrders — Optionen"
L["Show cast bar"] = "Buffleiste anzeigen"
L["Open edit: others may change my assignments"] = "Offene Bearbeitung: Andere dürfen meine Zuteilungen ändern"
L["Prefer greater blessings even for single members"] = "Große Segen auch bei einzelnen Mitgliedern bevorzugen"
L["Buff hunter pets"] = "Jäger-Begleiter segnen"
L["Buff warlock pets"] = "Hexenmeister-Begleiter segnen"
L["Show minimap button"] = "Minimap-Button anzeigen"
L["Show status messages in chat"] = "Statusmeldungen im Chat anzeigen"
L["Share assignments with legacy blessing addons"] = "Zuteilungen mit älteren Segens-Addons teilen"
L["Log sync messages (debug)"] = "Sync-Nachrichten protokollieren (Debug)"
L["Keep cast bar above other windows"] = "Leiste über anderen Fenstern halten"
L["Always show the Righteous Fury button"] = "Zorn-der-Gerechtigkeit-Knopf immer anzeigen"
L["Shows the Righteous Fury button even when you are not detected as a protection paladin or tank."] = "Zeigt den Knopf für Zorn der Gerechtigkeit auch dann, wenn du nicht als Schutz-Paladin oder Tank erkannt wirst."
-- options sections
L["General"] = "Allgemein"
-- first-blessing onboarding
L["you learned %s — it is now assigned to yourself; click the cast bar to use it"] = "%s gelernt — ist jetzt dir selbst zugeteilt; klicke die Buffleiste zum Wirken"
L["Group"] = "Gruppe"
L["Cast bar"] = "Buffleiste"
L["Windows & skin"] = "Fenster & Skin"
L["Blessings & pets"] = "Segen & Begleiter"
L["Group & chat"] = "Gruppe & Chat"
-- option tooltips
L["Shows or hides the round HolyOrders button on the minimap edge."] = "Zeigt oder versteckt den runden HolyOrders-Button am Minimap-Rand."
L["Prints routine status messages (sync, auto-planner results) to the chat. Errors and command replies always show."] = "Schreibt Routine-Statusmeldungen (Sync, Auto-Planer) in den Chat. Fehler und Befehls-Antworten erscheinen immer."
L["Records the addon sync traffic in the debug log (/ho log). Only needed for troubleshooting."] = "Protokolliert den Sync-Verkehr im Debug-Log (/ho log). Nur zur Fehlersuche nötig."
L["Shows the cast bar with one button per class duty. It appears automatically when you have blessings to cast."] = "Zeigt die Buffleiste mit einem Button je Klassen-Aufgabe. Sie erscheint automatisch, wenn Segen zu wirken sind."
L["Raises the bar above other addon windows (unit frames and the like) that would otherwise cover it."] = "Hebt die Leiste über andere Addon-Fenster (z. B. Unit-Frames), die sie sonst verdecken würden."
L["The direction in which the bar's buttons line up, starting at the handle."] = "Die Richtung, in der sich die Buttons ab dem Griff aufreihen."
L["Which side of a class button the member list opens on."] = "Auf welcher Seite eines Klassenbuttons die Mitgliederliste aufklappt."
L["Size of the cast bar. Applies immediately; a change made in combat applies after the fight."] = "Größe der Buffleiste. Greift sofort; eine Änderung im Kampf erst nach dem Kampf."
L["Size of the assignment window and the buff-request window."] = "Größe von Zuteilungs- und Segenswunsch-Fenster."
L["The addon's look. Switching needs a UI reload — a prompt appears."] = "Das Aussehen des Addons. Der Wechsel erfordert ein UI-Neuladen — eine Abfrage erscheint."
L["Casts the big 30-minute blessing even when only one member of a class is present. Costs a Symbol of Kings per cast."] = "Wirkt den großen 30-Minuten-Segen auch, wenn nur ein Mitglied einer Klasse da ist. Kostet je Wirken ein Symbol der Könige."
L["Includes hunter pets in planning and casting."] = "Bezieht Jäger-Begleiter in Planung und Buffen ein."
L["Includes warlock demons in planning and casting."] = "Bezieht Hexenmeister-Dämonen in Planung und Buffen ein."
L["The first blessing pets receive. When several paladins cover the owner's class, they stack further blessings on the pet: Kings, and Wisdom on mana pets."] = "Der erste Segen für Begleiter. Decken mehrere Paladine die Klasse des Besitzers ab, stapeln sie weitere Segen auf den Begleiter: Könige, und bei Mana-Begleitern Weisheit."
L["Allows the other paladins in your group to change your assignments. When off, only lead and assist may."] = "Erlaubt den anderen Paladinen deiner Gruppe, deine Zuteilungen zu ändern. Wenn aus, dürfen es nur Leiter und Assistent."
L["Broadcasts your own assignments in the format of older blessing addons so their users see your plan. One-way only; off by default."] = "Sendet deine eigenen Zuteilungen im Format älterer Segens-Addons, damit deren Nutzer deinen Plan sehen. Nur in eine Richtung; standardmäßig aus."
-- dropdown labels
L["Pet blessing"] = "Begleiter-Segen"
L["Bar grows"] = "Leiste wächst"
L["Fly-out opens"] = "Fly-out öffnet"
L["Skin"] = "Skin"
L["Cast bar scale"] = "Leisten-Skalierung"
L["Window scale"] = "Fenster-Skalierung"
L["the new skin applies after a UI reload — reload now?"] = "Der neue Skin greift nach einem UI-Neuladen — jetzt neu laden?"

-- assignment window
L["HolyOrders — Assignments"] = "HolyOrders — Zuteilungen"
L["expand or collapse all classes"] = "alle Klassen auf- oder zuklappen"
L["Save"] = "Speichern"
L["Run the deterministic auto-planner"] = "Deterministischen Auto-Planer ausführen"
L["Force rebuff: refresh everything before the pull"] = "Zwangs-Rebuff: vor dem Pull alles auffrischen"
L["Save the current plan for this paladin roster"] = "Aktuellen Plan für diese Paladin-Besetzung speichern"
L["Encounter toggle: swap Salvation for substitutes, click again to restore the previous plan (lead/assist)"] = "Encounter-Schalter: Rettung durch Ersatz-Segen ersetzen; erneut klicken stellt den vorherigen Plan wieder her (Leiter/Assistent)"
-- the button label: English shows the mode state, German uses action labels
-- ("Salv raus" = click removes Salvation, "Salv rein" = click restores it)
L["No-Salv OFF"] = "Salv raus"
L["No-Salv ON"] = "Salv rein"
-- pre-planning (expected paladins) and the lane swap
L["Add an expected paladin: assign their blessings before they join"] = "Erwarteten Paladin hinzufügen: Segen zuweisen, bevor er der Gruppe beitritt"
L["Pre-plan a paladin who has not joined yet — enter their name:"] = "Für einen Paladin vorplanen, der noch nicht in der Gruppe ist — Name eingeben:"
L["Click a paladin's name, then another, to swap their assignments"] = "Einen Paladinnamen anklicken, dann einen zweiten — tauscht ihre Zuweisungen"
L["Right-click removes this expected paladin"] = "Rechtsklick entfernt diesen erwarteten Paladin"
L["Synchronizing with the group..."] = "Synchronisiere mit der Gruppe ..."
L["swap: %s selected — click another paladin's name to swap assignments (same name cancels)"] = "Tausch: %s gewählt — zweiten Paladinnamen anklicken zum Tauschen (gleicher Name bricht ab)"
L["swap cancelled"] = "Tausch abgebrochen"
L["assignments swapped: %s and %s"] = "Zuweisungen getauscht: %s und %s"
L["swap failed: "] = "Tausch fehlgeschlagen: "
-- window legend, plain language ("Nüchtern & knapp")
L["Click an icon = pick a blessing · right-click = remove · class name = show members"] = "Icon anklicken = Segen wählen · Rechtsklick = entfernen · Klassenname = Mitglieder zeigen"
L["Click a member's name = change their spec/role · right-click the name = mark as tank"] = "Name anklicken = Skillung/Rolle wechseln · Rechtsklick auf den Namen = als Tank markieren"
L["Shift-click an icon changes how it is cast:"] = "Shift-Klick auf ein Icon ändert die Wirk-Art:"
L["|cff40c0ffA|r automatic: big from %d members, small otherwise — |cffffd100G|r always big (whole class, 1 Symbol) — |cff40ff40S|r always small (10 min each)"] = "|cff40c0ffA|r automatisch: Groß ab %d Leuten, sonst Klein — |cffffd100G|r immer Groß (ganze Klasse, 1 Symbol) — |cff40ff40S|r immer Klein (je 10 Min)"
L["no assignment"] = "keine Zuteilung"
L["no blessing assigned"] = "Kein Segen zugewiesen"
L["no blessing assigned — wheel to assign"] = "Kein Segen zugewiesen — mit dem Mausrad zuweisen"
L["click: next blessing — right-click: clear"] = "Klick: nächster Segen — Rechtsklick: leeren"
L["shift-click: change the cast mode"] = "Shift-Klick: Wirkmodus ändern"
L["mode: auto — greater from %d+ members, singles otherwise"] = "Modus: auto — Groß ab %d Mitgliedern, sonst Einzelsegen"
L["with %d member(s) now: %s"] = "mit aktuell %d Mitglied(ern): %s"
L["greater (30 min, whole class, 1 Symbol of Kings)"] = "Groß (30 Min, ganze Klasse, 1 Symbol der Könige)"
L["10-min singles (too few members for greater)"] = "10-Min-Einzelsegen (zu wenige Mitglieder für Groß)"
L["mode: greater — always the Greater Blessing: 30 min, hits the whole class, costs a Symbol of Kings per cast"] = "Modus: Groß — immer der Große Segen: 30 Min, trifft die ganze Klasse, kostet je Wirken ein Symbol der Könige"
L["mode: normal — always 10-min single blessings on each member, no reagent"] = "Modus: normal — immer 10-Min-Einzelsegen auf jedes Mitglied, ohne Reagenz"
L["override by %s: %s"] = "Überschreibung durch %s: %s"
L["inherited from class assignment: %s"] = "geerbt aus Klassen-Zuteilung: %s"
L["remembered preference: %s"] = "Gemerkte Vorliebe: %s"
L["none"] = "keine"
L["(pet of %s)"] = "(Begleiter von %s)"
L["[tank]"] = "[Tank]"
L["%s — all covered"] = "%s — alle versorgt"

-- cast bar
L["left: %s on %s"] = "Links: %s auf %s"
L["right: %s (single)"] = "Rechts: %s (Einzelsegen)"
L["right-click: %s (whole class, 1 Symbol)"] = "Rechtsklick: %s (ganze Klasse, 1 Symbol)"
L["all remaining targets are out of range"] = "alle verbleibenden Ziele sind außer Reichweite"
L["%d out of range (skipped)"] = "%d außer Reichweite (übersprungen)"
L["%d missing"] = "%d fehlen"
L["%d expiring soon"] = "%d laufen bald ab"
-- handle tooltip: "[Gesture] action" lines
L["Left-Click"] = "Linksklick"
L["Right-Click"] = "Rechtsklick"
L["Ctrl-Left-Drag"] = "Strg-Linksklick ziehen"
L["Shift-Right-Click"] = "Shift-Rechtsklick"
L["Open the assignment window"] = "Zuteilungsfenster öffnen"
L["Toggle the force rebuff (pre-pull refresh)"] = "Zwangs-Rebuff umschalten (vor dem Pull)"
L["Move the cast bar"] = "Buffleiste verschieben"
L["Open the options"] = "Optionen öffnen"
L["force rebuff is running — right-click cancels"] = "Zwangs-Rebuff läuft — Rechtsklick bricht ab"
L["mouse wheel: change my assignment"] = "Mausrad: meine Zuteilung wechseln"
L["in combat: click cycles through the class's members"] = "Im Kampf: Klick wirkt reihum auf die Mitglieder der Klasse"

-- cast-bar class fly-out
L["no buff assigned"] = "Kein Segen zugewiesen"
L["has the blessing"] = "hat den Segen"
L["missing the blessing"] = "Segen fehlt"
L["out of range"] = "außer Reichweite"
L["all covered"] = "alles abgedeckt"
L["wheel: change blessing — right-click: clear"] = "Mausrad: Segen wechseln — Rechtsklick: leeren"
L["left-click: cast — wheel: change — right-click: clear"] = "Linksklick: wirken — Mausrad: wechseln — Rechtsklick: leeren"
L["assignment changes apply after combat"] = "Zuteilungsänderungen werden nach dem Kampf übernommen"

-- paladin aura
L["Aura"] = "Aura"
-- the protection threat self-buff slot on the cast bar
L["Fury"] = "Zorn"
L["active"] = "aktiv"
L["MISSING — click to cast"] = "FEHLT — klicken zum Wirken"
L["My Aura"] = "Meine Aura"
L["no aura assigned"] = "Keine Aura zugewiesen"
L["mouse wheel: change your aura"] = "Mausrad: deine Aura wechseln"
L["aura: %s"] = "Aura: %s"
L["click: next aura — right-click: clear"] = "Klick: nächste Aura — Rechtsklick: leeren"

-- minimap button
L["click: assignment window"] = "Klick: Zuteilungsfenster"
L["click: buff request"] = "Klick: Segenswunsch"
L["right-click: force rebuff"] = "Rechtsklick: Zwangs-Rebuff"
L["shift-click: options"] = "Shift-Klick: Optionen"
L["drag: move this button"] = "Ziehen: Button verschieben"

-- buff requests
L["Buff Request"] = "Segenswunsch"
L["requesting: %s"] = "Wunsch: %s"
L["no request"] = "kein Wunsch"
L["requested: %s"] = "gewünscht: %s"
L["Clear"] = "Leeren"
L["click a blessing to request it for yourself"] = "Klicke einen Segen, um ihn für dich zu erbitten"
L["preferences: %s"] = "Vorlieben: %s"
L["click blessings in priority order — click again to remove"] = "Segen in Prioritätsreihenfolge anklicken — erneut klicken entfernt"

-- frequent chat messages
L["force rebuff cancelled"] = "Zwangs-Rebuff abgebrochen"
L["force rebuff: refreshing everything older than 2 minutes (ends when all fresh)"] = "Zwangs-Rebuff: alles älter als 2 Minuten wird erneuert (endet, wenn alles frisch ist)"
L["force rebuff complete — all assigned buffs are fresh"] = "Zwangs-Rebuff abgeschlossen — alle zugeteilten Segen sind frisch"
L["plan broadcast to the group"] = "Plan an die Gruppe gesendet"
L["plan is local — only your own assignments sync (lead/assist can broadcast all)"] = "Plan ist lokal — nur die eigenen Zuteilungen werden synchronisiert (Leiter/Assistent kann alles senden)"
L["stored plan applied for this paladin roster"] = "Gespeicherter Plan für diese Paladin-Besetzung angewendet"
L["stored plan for this roster available — '/ho plan apply' loads it (your unsaved edits are kept until then)"] = "Gespeicherter Plan für diese Besetzung verfügbar — '/ho plan apply' lädt ihn (ungespeicherte Änderungen bleiben bis dahin erhalten)"
L["in a raid only lead/assist may flag others as tank"] = "Im Schlachtzug dürfen nur Leiter/Assistent andere als Tank markieren"
L["can't move the bar in combat — will reset it after combat"] = "Leiste kann im Kampf nicht bewegt werden — sie wird nach dem Kampf zurückgesetzt"
L["this duty is a single-member override — change it in the assignment window"] = "Diese Aufgabe ist eine Einzelmitglied-Überschreibung — ändere sie im Zuteilungsfenster"
