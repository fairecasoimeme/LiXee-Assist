package com.lixee.assist

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import androidx.core.graphics.PathParser

/**
 * Dessine l'icône d'un groupe d'actions à partir de son tracé SVG.
 *
 * Depuis le firmware 2.23, la box ne stocke plus un émoji mais le nom d'une
 * icône Material Design, dont elle sert le tracé dans `/agicons.js`. Ces tracés
 * vivent sur une grille de 24×24 — la convention MDI — et se lisent tels quels
 * par le PathParser d'Android : aucune copie du jeu d'icônes n'est embarquée
 * dans l'app, et une icône ajoutée par un firmware ultérieur s'affichera sans
 * mise à jour.
 *
 * Monochrome, comme sur la box : une seule teinte, celle du groupe.
 */
object GroupIcon {

    private const val GRID = 24f
    private const val SIZE_PX = 144

    /** `null` si le tracé est illisible — le widget masque alors l'icône. */
    fun render(pathData: String, color: Int): Bitmap? {
        val path = try {
            PathParser.createPathFromPathData(pathData)
        } catch (e: RuntimeException) {
            return null
        } ?: return null

        val bitmap = Bitmap.createBitmap(SIZE_PX, SIZE_PX, Bitmap.Config.ARGB_8888)
        val scale = SIZE_PX / GRID
        path.transform(Matrix().apply { setScale(scale, scale) })

        Canvas(bitmap).drawPath(path, Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL
            this.color = color
        })
        return bitmap
    }

    /**
     * Le champ `icon` porte-t-il un nom d'icône plutôt qu'un émoji ?
     *
     * Les noms MDI s'écrivent en minuscules et tirets (`window-shutter-open`).
     * Un tel nom sans tracé connu ne doit surtout pas s'afficher en texte : le
     * widget montrerait « window-shutter » là où l'on attend un dessin.
     */
    fun isIconName(icon: String) = icon.matches(Regex("^[a-z0-9]+(-[a-z0-9]+)*$"))
}
