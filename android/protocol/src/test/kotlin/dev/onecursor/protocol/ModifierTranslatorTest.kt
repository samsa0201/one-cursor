package dev.onecursor.protocol

import kotlin.test.Test
import kotlin.test.assertEquals

class ModifierTranslatorTest {
    @Test
    fun superMappedToControl() {
        val t = ModifierTranslator()
        t.map(KeyModifierIds.SUPER, KeyModifierIds.CONTROL)
        assertEquals(KeyIds.CONTROL_R, t.translateKey(KeyIds.SUPER_R))
        assertEquals(KeyModifiers.CONTROL or KeyModifiers.CAPS_LOCK, t.translateMask(KeyModifiers.SUPER or KeyModifiers.CAPS_LOCK))
        assertEquals('c'.code, t.translateKey('c'.code))
    }

    @Test
    fun mapToNoneDropsModifier() {
        val t = ModifierTranslator()
        t.map(KeyModifierIds.ALT, KeyModifierIds.NULL)
        assertEquals(KeyIds.NONE, t.translateKey(KeyIds.ALT_L))
        assertEquals(KeyModifiers.SHIFT, t.translateMask(KeyModifiers.SHIFT or KeyModifiers.ALT))
    }
}
