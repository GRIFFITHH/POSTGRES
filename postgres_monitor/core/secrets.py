import os


class SecretResolutionError(RuntimeError):
    pass


def resolve_secret(secret_ref: str) -> str:
    if secret_ref.startswith("env:"):
        env_key = secret_ref.split(":", 1)[1]
        secret = os.getenv(env_key)
        if not secret:
            raise SecretResolutionError(f"Environment variable '{env_key}' is missing")
        return secret

    raise SecretResolutionError(
        "Unsupported secret_ref format. Use env:YOUR_ENV_VAR"
    )
