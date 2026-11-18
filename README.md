# dokku-no-http2

A Dokku plugin that serves Dokku's own nginx vhost template with HTTP/2 removed.
Every app on the host then speaks HTTP/1.1 over TLS; nothing else in the vhost changes.

Dokku's `nginx.conf.sigil` enables HTTP/2 on every TLS listener and has no property to
turn it off. Use this plugin when HTTP/2 has to go host-wide, for example while an
nginx HTTP/2 vulnerability is unpatched in the distribution package.

## How it works

The plugin implements Dokku's `nginx-app-template-source` trigger, which Dokku has
since v0.22. Older releases never call it, so there the plugin has no effect. For the
vhost template (`app-config`) it reads the stock template from the `nginx-vhosts` plugin,
removes `http2 on;` lines and every `http2` on `listen` lines, including the
`{{ if eq $.HTTP2_SUPPORTED "true" }}http2{{ end }}` form of v0.22 to v0.37, writes the result to
`/var/lib/dokku/data/no-http2/nginx.conf.sigil` and hands that path to Dokku. Every
other template type stays Dokku's.

The edit is fail-closed. If HTTP/2 is still enabled after the edit, for example because
a Dokku upgrade changed the template's shape, the trigger prints the offending lines and
exits non-zero instead of handing Dokku a template that still enables HTTP/2.

nginx negotiates HTTP/2 per listen socket, so one vhost with HTTP/2 on a shared
`address:port` re-enables it for all of them. Removing it from the template removes it
everywhere. An app that ships its own `nginx.conf.sigil` outranks this plugin and keeps
whatever that file says.

Clients that need HTTP/2, such as native gRPC, stop working.

## Install

```sh
dokku plugin:install https://github.com/civico-de/dokku-no-http2.git --committish 0.1.1 --name no-http2
dokku proxy:build-config --all
systemctl restart nginx
```

Use a restart, not a reload. After a reload the old workers keep serving their
established HTTP/2 connections until those connections close.

Check that no vhost still offers HTTP/2:

```sh
grep -lE 'listen[^;]*[[:space:]]http2[[:space:];]|^[[:space:]]*http2[[:space:]]+on' /home/dokku/*/nginx.conf
echo | openssl s_client -connect 127.0.0.1:443 -servername <domain> -alpn h2,http/1.1 2>/dev/null | grep ALPN
```

The `grep` prints nothing, and the ALPN line reads `http/1.1`.

## Remove

```sh
dokku plugin:uninstall no-http2
dokku proxy:build-config --all
systemctl restart nginx
```

## Test

```sh
test/run.sh
```

The test runs the trigger against the stock templates in `test/fixtures/`. Each one has
to come out with no HTTP/2 and no other edits. The test also feeds the trigger template
shapes it has to refuse. Add the template of a new Dokku release under
`test/fixtures/nginx.conf.sigil.<version>` before you deploy that release. The fixtures
are copies of Dokku's MIT-licensed `plugins/nginx-vhosts/templates/nginx.conf.sigil`
(see `LICENSE.txt`).
