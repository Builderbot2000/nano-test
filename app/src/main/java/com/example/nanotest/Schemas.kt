package com.example.nanotest

import com.google.mlkit.genai.schema.annotations.Generable
import com.google.mlkit.genai.schema.annotations.Guide
import kotlin.reflect.KClass

/*
 * Output shapes for structured output (`schema` extra / `-Schema` flag). AICore constrains decoding to
 * the class's schema, so replies always parse. The genai-schema-compiler KSP processor generates the
 * schema from these annotations at build time.
 *
 * To add one: declare a @Generable data class, register it in SCHEMAS, rebuild and reinstall.
 */

@Generable(description = "Sentiment of a piece of text")
data class Sentiment(
    @Guide(description = "Overall sentiment", enumValues = ["positive", "negative", "neutral"])
    val label: String,
    @Guide(description = "Confidence from 0 to 1", minimum = 0.0, maximum = 1.0)
    val confidence: Double,
)

@Generable(description = "A cooking recipe")
data class Recipe(
    @Guide(description = "Name of the dish")
    val title: String,
    @Guide(description = "Ingredients with quantities", minItems = 1)
    val ingredients: List<String>,
    @Guide(description = "Total time in minutes", minimum = 1.0)
    val minutes: Int,
)

/** Name used on the command line → class. */
val SCHEMAS: Map<String, KClass<*>> = mapOf(
    "sentiment" to Sentiment::class,
    "recipe" to Recipe::class,
)
