// The published @aaif/goose-sdk npm package (0.20.2, the latest available)
// doesn't export zRecipeDto yet — upstream builds it from the workspace-local
// ui/sdk source, not the published package. Vendored directly from
// goose-upstream/ui/sdk/src/generated/zod.gen.ts instead of pulling the whole
// SDK build pipeline into this standalone fork.
import { zRecipeDto } from '../goose-sdk-zod.gen';
import { zodToJsonSchema } from 'zod-to-json-schema';

type JsonSchema = Record<string, unknown>;

const recipeDescription =
  'A Recipe represents a reusable agent configuration with instructions, optional prompt, parameters, supported extensions, settings, and subrecipes.';

let recipeJsonSchema: JsonSchema | null = null;

export function getRecipeJsonSchema(): JsonSchema {
  if (!recipeJsonSchema) {
    recipeJsonSchema = {
      ...(zodToJsonSchema(zRecipeDto, { $refStrategy: 'none' }) as JsonSchema),
      title: 'Recipe',
      description: recipeDescription,
    };
  }

  return recipeJsonSchema;
}
