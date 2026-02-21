# ZAI Provider Setup

The ZAI provider is now configured in the application and supports the following models:

- `glm-5` (default)
- `glm-4`

## Configuration

The ZAI provider is defined in the `settings.json` file:

```json
{
  "id": "zai",
  "env_vars": ["ZAI_API_KEY"],
  "endpoint": "https://api.zai.ai/v1/chat/completions",
  "models_endpoint": "https://api.zai.ai/v1/models",
  "models": [
    "glm-5",
    "glm-4"
  ]
}
```

## Setup

To use the ZAI provider:

1. Set your API key:
   ```bash
   export ZAI_API_KEY=your_api_key_here
   ```

2. Or add it to your `~/.config/zagent/providers.env` file:
   ```
   ZAI_API_KEY=your_api_key_here
   ```

3. Select the ZAI provider in the application:
   - The default model for ZAI is `glm-5`

## Implementation Details

- **File**: `src/provider.zig`
- **Settings**: `.config/zagent/settings.json`
- **Default model priority**: `glm-5` → `glm-4`

The implementation includes:
- Provider specification in `settings.json`
- Default model selection logic with `zai_priority`
- Fallback configuration in `getProviderConfig()`
