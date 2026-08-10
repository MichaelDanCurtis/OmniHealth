# Running OmniHealth locally against a real wger server

Verified working on 2026-08-10 (macOS, Docker 29.6, Xcode 26.6).

The published `wger/server` image assumes Postgres and gunicorn. Three things
have to be overridden to get a throwaway local instance, and none of them are
obvious from the image docs.

## Start the server

```bash
docker run -d --name omnihealth-wger \
  --env-file jwt.env \
  -p 8000:8000 \
  -e DJANGO_DB_ENGINE=django.db.backends.sqlite3 \
  -e DJANGO_DB_DATABASE=/home/wger/db/database.sqlite \
  -e DJANGO_DB_USER=wger -e DJANGO_DB_PASSWORD=wger \
  -e DJANGO_DB_HOST=localhost -e DJANGO_DB_PORT=5432 \
  -e SECRET_KEY=local-dev-only-not-a-real-secret \
  -e SITE_URL=http://localhost:8000 \
  -e WGER_INSTANCE_TYPE=demo \
  -e ALLOW_REGISTRATION=True \
  wger/server:latest
```

### The three gotchas

1. **`DJANGO_DB_*` are required even for sqlite.** The image reads
   `DJANGO_DB_USER`, `PASSWORD`, `HOST` and `PORT` unconditionally at settings
   load; without them it dies with `ImproperlyConfigured` before it ever looks at
   the engine. The values are ignored for sqlite — they just have to exist.

2. **Map to port 8000, not 80.** The container runs
   `manage.py runserver 0.0.0.0:8000`. Mapping `-p 8000:80` looks right and
   silently produces a container that reports `Up` while nothing answers. The
   symptom is `curl` returning `000` against a healthy-looking container.

3. **JWT keys must be generated, or login fails.** The Flutter app authenticates
   with JWT. Without keys the server starts fine and warns only in the log:
   `JWT_PRIVATE_KEY / JWT_PUBLIC_KEY are not set`. Generate them from a running
   container and feed them back in:

   ```bash
   docker exec omnihealth-wger python3 manage.py generate-jwt-keys \
     | grep -E '^JWT_(PRIVATE|PUBLIC)_KEY=' > jwt.env
   ```

   Then restart with `--env-file jwt.env`. The keys are single-line base64, so
   they pass through an env file cleanly.

## Wait for it

Migrations take a couple of minutes on first run:

```bash
until [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
  http://localhost:8000/api/v2/)" != "000" ]; do sleep 5; done
```

**Credentials:** the image resets `admin` to `adminadmin` on first boot and
prints it in the log.

## Point the app at it

In the app's login screen, open **ADVANCED** and set the server URL to
`http://localhost:8000`. From the iOS Simulator `localhost` resolves to the host
Mac, so this works as-is. An Android emulator would need `http://10.0.2.2:8000`.

## Run the app

```bash
flutter build ios --debug --simulator --no-codesign
xcrun simctl boot "iPhone 16 Pro"
xcrun simctl install booted build/ios/iphonesimulator/Runner.app
xcrun simctl launch booted de.wger.flutter.community
xcrun simctl io booted screenshot /tmp/shot.png
```

## What has and has not been verified this way

**Verified:** the app builds for iOS and macOS, launches on the simulator, and
reaches its login screen with the AI module's `ProviderScope` overrides active.
That rules out the wiring crashing at startup.

**Not verified:** the end-to-end path of logging in, entering a provider API key,
and holding a conversation that reads and writes real rows. Doing that needs
working simulator *input* automation; the screenshot path via `simctl` works but
`simctl` cannot tap. Until someone drives it by hand or the input tooling works,
the claim "the bindings return real data" rests on compile-time types and the
unit suite's fakes, not on observation.

## Tear down

```bash
docker rm -f omnihealth-wger
```
