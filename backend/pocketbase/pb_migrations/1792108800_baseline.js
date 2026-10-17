migrate((app) => {
  // Baseline captured from collection metadata only; no records or secret values.
  const baseline = [
  {
    "id": "_pb_users_auth_",
    "name": "users",
    "type": "auth",
    "listRule": "id = @request.auth.id",
    "viewRule": "id = @request.auth.id",
    "createRule": "",
    "updateRule": "id = @request.auth.id",
    "deleteRule": "id = @request.auth.id",
    "indexes": [
      "CREATE UNIQUE INDEX `idx_tokenKey__pb_users_auth_` ON `users` (`tokenKey`)",
      "CREATE UNIQUE INDEX `idx_email__pb_users_auth_` ON `users` (`email`) WHERE `email` != ''"
    ],
    "fields": [
      {
        "autogeneratePattern": "[a-z0-9]{15}",
        "help": "",
        "hidden": false,
        "id": "text3208210256",
        "max": 15,
        "min": 15,
        "name": "id",
        "pattern": "^[a-z0-9]+$",
        "presentable": false,
        "primaryKey": true,
        "required": true,
        "system": true,
        "type": "text"
      },
      {
        "cost": 0,
        "help": "",
        "hidden": true,
        "id": "password901924565",
        "max": 0,
        "min": 8,
        "name": "password",
        "pattern": "",
        "presentable": false,
        "required": true,
        "system": true,
        "type": "password"
      },
      {
        "autogeneratePattern": "[a-zA-Z0-9]{50}",
        "help": "",
        "hidden": true,
        "id": "text2504183744",
        "max": 60,
        "min": 30,
        "name": "tokenKey",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": true,
        "system": true,
        "type": "text"
      },
      {
        "exceptDomains": null,
        "help": "",
        "hidden": false,
        "id": "email3885137012",
        "name": "email",
        "onlyDomains": null,
        "presentable": false,
        "required": true,
        "system": true,
        "type": "email"
      },
      {
        "help": "",
        "hidden": false,
        "id": "bool1547992806",
        "name": "emailVisibility",
        "presentable": false,
        "required": false,
        "system": true,
        "type": "bool"
      },
      {
        "help": "",
        "hidden": false,
        "id": "bool256245529",
        "name": "verified",
        "presentable": false,
        "required": false,
        "system": true,
        "type": "bool"
      },
      {
        "autogeneratePattern": "",
        "help": "",
        "hidden": false,
        "id": "text1579384326",
        "max": 255,
        "min": 0,
        "name": "name",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": false,
        "system": false,
        "type": "text"
      },
      {
        "help": "",
        "hidden": false,
        "id": "file376926767",
        "maxSelect": 1,
        "maxSize": 0,
        "mimeTypes": [
          "image/jpeg",
          "image/png",
          "image/svg+xml",
          "image/gif",
          "image/webp"
        ],
        "name": "avatar",
        "presentable": false,
        "protected": false,
        "required": false,
        "system": false,
        "thumbs": null,
        "type": "file"
      },
      {
        "hidden": false,
        "id": "autodate2990389176",
        "name": "created",
        "onCreate": true,
        "onUpdate": false,
        "presentable": false,
        "system": false,
        "type": "autodate"
      },
      {
        "hidden": false,
        "id": "autodate3332085495",
        "name": "updated",
        "onCreate": true,
        "onUpdate": true,
        "presentable": false,
        "system": false,
        "type": "autodate"
      }
    ]
  },
  {
    "id": "mm_licenses",
    "name": "licenses",
    "type": "base",
    "listRule": "@request.auth.id != \"\" && redeemed_by = @request.auth.id",
    "viewRule": "@request.auth.id != \"\" && redeemed_by = @request.auth.id",
    "createRule": null,
    "updateRule": null,
    "deleteRule": null,
    "indexes": [
      "CREATE UNIQUE INDEX idx_licenses_code ON licenses (code)",
      "CREATE INDEX idx_licenses_redeemed_by ON licenses (redeemed_by)"
    ],
    "fields": [
      {
        "autogeneratePattern": "[a-z0-9]{15}",
        "help": "",
        "hidden": false,
        "id": "text3208210256",
        "max": 15,
        "min": 15,
        "name": "id",
        "pattern": "^[a-z0-9]+$",
        "presentable": false,
        "primaryKey": true,
        "required": true,
        "system": true,
        "type": "text"
      },
      {
        "autogeneratePattern": "",
        "help": "",
        "hidden": true,
        "id": "text1997877400",
        "max": 64,
        "min": 12,
        "name": "code",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": true,
        "system": false,
        "type": "text"
      },
      {
        "autogeneratePattern": "",
        "help": "",
        "hidden": false,
        "id": "text36530578",
        "max": 16,
        "min": 0,
        "name": "code_hint",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": false,
        "system": false,
        "type": "text"
      },
      {
        "help": "",
        "hidden": false,
        "id": "select3713686397",
        "maxSelect": 1,
        "name": "plan",
        "presentable": false,
        "required": true,
        "system": false,
        "type": "select",
        "values": [
          "pro",
          "lifetime"
        ]
      },
      {
        "help": "",
        "hidden": false,
        "id": "number3098838237",
        "max": null,
        "min": 0,
        "name": "duration_days",
        "onlyInt": true,
        "presentable": false,
        "required": false,
        "system": false,
        "type": "number"
      },
      {
        "help": "",
        "hidden": false,
        "id": "number2247365854",
        "max": 100,
        "min": 1,
        "name": "max_devices",
        "onlyInt": true,
        "presentable": false,
        "required": false,
        "system": false,
        "type": "number"
      },
      {
        "help": "",
        "hidden": false,
        "id": "select2063623452",
        "maxSelect": 1,
        "name": "status",
        "presentable": false,
        "required": true,
        "system": false,
        "type": "select",
        "values": [
          "available",
          "redeemed",
          "revoked"
        ]
      },
      {
        "cascadeDelete": false,
        "collectionId": "_pb_users_auth_",
        "help": "",
        "hidden": false,
        "id": "relation4060325122",
        "maxSelect": 1,
        "minSelect": 0,
        "name": "redeemed_by",
        "presentable": false,
        "required": false,
        "system": false,
        "type": "relation"
      },
      {
        "help": "",
        "hidden": false,
        "id": "date2812250748",
        "max": "",
        "min": "",
        "name": "redeemed_at",
        "presentable": false,
        "required": false,
        "system": false,
        "type": "date"
      },
      {
        "help": "",
        "hidden": false,
        "id": "select1602912115",
        "maxSelect": 1,
        "name": "source",
        "presentable": false,
        "required": false,
        "system": false,
        "type": "select",
        "values": [
          "stripe",
          "manual",
          "promo",
          "demo"
        ]
      },
      {
        "autogeneratePattern": "",
        "help": "",
        "hidden": true,
        "id": "text1463054787",
        "max": 200,
        "min": 0,
        "name": "order_ref",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": false,
        "system": false,
        "type": "text"
      },
      {
        "autogeneratePattern": "",
        "help": "",
        "hidden": true,
        "id": "text3485334036",
        "max": 500,
        "min": 0,
        "name": "note",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": false,
        "system": false,
        "type": "text"
      },
      {
        "hidden": false,
        "id": "autodate2990389176",
        "name": "created",
        "onCreate": true,
        "onUpdate": false,
        "presentable": false,
        "system": false,
        "type": "autodate"
      },
      {
        "hidden": false,
        "id": "autodate3332085495",
        "name": "updated",
        "onCreate": true,
        "onUpdate": true,
        "presentable": false,
        "system": false,
        "type": "autodate"
      }
    ]
  },
  {
    "id": "mm_entitlements",
    "name": "plan_entitlements",
    "type": "base",
    "listRule": "@request.auth.id != \"\" && user = @request.auth.id",
    "viewRule": "@request.auth.id != \"\" && user = @request.auth.id",
    "createRule": null,
    "updateRule": null,
    "deleteRule": null,
    "indexes": [
      "CREATE UNIQUE INDEX idx_entitlements_user ON plan_entitlements (user)"
    ],
    "fields": [
      {
        "autogeneratePattern": "[a-z0-9]{15}",
        "help": "",
        "hidden": false,
        "id": "text3208210256",
        "max": 15,
        "min": 15,
        "name": "id",
        "pattern": "^[a-z0-9]+$",
        "presentable": false,
        "primaryKey": true,
        "required": true,
        "system": true,
        "type": "text"
      },
      {
        "cascadeDelete": true,
        "collectionId": "_pb_users_auth_",
        "help": "",
        "hidden": false,
        "id": "relation2375276105",
        "maxSelect": 1,
        "minSelect": 0,
        "name": "user",
        "presentable": false,
        "required": true,
        "system": false,
        "type": "relation"
      },
      {
        "help": "",
        "hidden": false,
        "id": "select3713686397",
        "maxSelect": 1,
        "name": "plan",
        "presentable": false,
        "required": true,
        "system": false,
        "type": "select",
        "values": [
          "free",
          "pro"
        ]
      },
      {
        "help": "",
        "hidden": false,
        "id": "select2063623452",
        "maxSelect": 1,
        "name": "status",
        "presentable": false,
        "required": true,
        "system": false,
        "type": "select",
        "values": [
          "active",
          "expired",
          "revoked"
        ]
      },
      {
        "help": "",
        "hidden": false,
        "id": "select1602912115",
        "maxSelect": 1,
        "name": "source",
        "presentable": false,
        "required": false,
        "system": false,
        "type": "select",
        "values": [
          "signup",
          "license",
          "stripe",
          "demo",
          "manual"
        ]
      },
      {
        "cascadeDelete": false,
        "collectionId": "mm_licenses",
        "help": "",
        "hidden": false,
        "id": "relation1466496025",
        "maxSelect": 1,
        "minSelect": 0,
        "name": "license",
        "presentable": false,
        "required": false,
        "system": false,
        "type": "relation"
      },
      {
        "help": "",
        "hidden": false,
        "id": "date261981154",
        "max": "",
        "min": "",
        "name": "expires_at",
        "presentable": false,
        "required": false,
        "system": false,
        "type": "date"
      },
      {
        "help": "",
        "hidden": false,
        "id": "number2247365854",
        "max": 100,
        "min": 0,
        "name": "max_devices",
        "onlyInt": true,
        "presentable": false,
        "required": false,
        "system": false,
        "type": "number"
      },
      {
        "hidden": false,
        "id": "autodate2990389176",
        "name": "created",
        "onCreate": true,
        "onUpdate": false,
        "presentable": false,
        "system": false,
        "type": "autodate"
      },
      {
        "hidden": false,
        "id": "autodate3332085495",
        "name": "updated",
        "onCreate": true,
        "onUpdate": true,
        "presentable": false,
        "system": false,
        "type": "autodate"
      }
    ]
  },
  {
    "id": "mm_devices",
    "name": "devices",
    "type": "base",
    "listRule": "@request.auth.id != \"\" && user = @request.auth.id",
    "viewRule": "@request.auth.id != \"\" && user = @request.auth.id",
    "createRule": null,
    "updateRule": null,
    "deleteRule": "@request.auth.id != \"\" && user = @request.auth.id",
    "indexes": [
      "CREATE UNIQUE INDEX idx_devices_user_device ON devices (user, device_id)",
      "CREATE INDEX idx_devices_user_seen ON devices (user, last_seen)"
    ],
    "fields": [
      {
        "autogeneratePattern": "[a-z0-9]{15}",
        "help": "",
        "hidden": false,
        "id": "text3208210256",
        "max": 15,
        "min": 15,
        "name": "id",
        "pattern": "^[a-z0-9]+$",
        "presentable": false,
        "primaryKey": true,
        "required": true,
        "system": true,
        "type": "text"
      },
      {
        "cascadeDelete": true,
        "collectionId": "_pb_users_auth_",
        "help": "",
        "hidden": false,
        "id": "relation2375276105",
        "maxSelect": 1,
        "minSelect": 0,
        "name": "user",
        "presentable": false,
        "required": true,
        "system": false,
        "type": "relation"
      },
      {
        "autogeneratePattern": "",
        "help": "",
        "hidden": false,
        "id": "text2493827028",
        "max": 64,
        "min": 16,
        "name": "device_id",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": true,
        "system": false,
        "type": "text"
      },
      {
        "autogeneratePattern": "",
        "help": "",
        "hidden": false,
        "id": "text1579384326",
        "max": 200,
        "min": 0,
        "name": "name",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": false,
        "system": false,
        "type": "text"
      },
      {
        "autogeneratePattern": "",
        "help": "",
        "hidden": false,
        "id": "text3616895705",
        "max": 100,
        "min": 0,
        "name": "model",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": false,
        "system": false,
        "type": "text"
      },
      {
        "autogeneratePattern": "",
        "help": "",
        "hidden": false,
        "id": "text2755536204",
        "max": 40,
        "min": 0,
        "name": "os_version",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": false,
        "system": false,
        "type": "text"
      },
      {
        "autogeneratePattern": "",
        "help": "",
        "hidden": false,
        "id": "text1380012942",
        "max": 40,
        "min": 0,
        "name": "app_version",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": false,
        "system": false,
        "type": "text"
      },
      {
        "help": "",
        "hidden": false,
        "id": "date846843460",
        "max": "",
        "min": "",
        "name": "last_seen",
        "presentable": false,
        "required": false,
        "system": false,
        "type": "date"
      },
      {
        "hidden": false,
        "id": "autodate2990389176",
        "name": "created",
        "onCreate": true,
        "onUpdate": false,
        "presentable": false,
        "system": false,
        "type": "autodate"
      },
      {
        "hidden": false,
        "id": "autodate3332085495",
        "name": "updated",
        "onCreate": true,
        "onUpdate": true,
        "presentable": false,
        "system": false,
        "type": "autodate"
      }
    ]
  },
  {
    "id": "mm_app_releases",
    "name": "app_releases",
    "type": "base",
    "listRule": "published = true",
    "viewRule": "published = true",
    "createRule": null,
    "updateRule": null,
    "deleteRule": null,
    "indexes": [
      "CREATE UNIQUE INDEX idx_releases_version_channel ON app_releases (version, channel)"
    ],
    "fields": [
      {
        "autogeneratePattern": "[a-z0-9]{15}",
        "help": "",
        "hidden": false,
        "id": "text3208210256",
        "max": 15,
        "min": 15,
        "name": "id",
        "pattern": "^[a-z0-9]+$",
        "presentable": false,
        "primaryKey": true,
        "required": true,
        "system": true,
        "type": "text"
      },
      {
        "autogeneratePattern": "",
        "help": "",
        "hidden": false,
        "id": "text3206337475",
        "max": 40,
        "min": 0,
        "name": "version",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": true,
        "system": false,
        "type": "text"
      },
      {
        "help": "",
        "hidden": false,
        "id": "number3181441755",
        "max": null,
        "min": 0,
        "name": "build",
        "onlyInt": true,
        "presentable": false,
        "required": false,
        "system": false,
        "type": "number"
      },
      {
        "help": "",
        "hidden": false,
        "id": "select2734263879",
        "maxSelect": 1,
        "name": "channel",
        "presentable": false,
        "required": true,
        "system": false,
        "type": "select",
        "values": [
          "stable",
          "beta"
        ]
      },
      {
        "autogeneratePattern": "",
        "help": "",
        "hidden": false,
        "id": "text117053000",
        "max": 20,
        "min": 0,
        "name": "min_os",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": false,
        "system": false,
        "type": "text"
      },
      {
        "exceptDomains": null,
        "help": "",
        "hidden": false,
        "id": "url3730845939",
        "name": "download_url",
        "onlyDomains": null,
        "presentable": false,
        "required": false,
        "system": false,
        "type": "url"
      },
      {
        "autogeneratePattern": "",
        "help": "",
        "hidden": false,
        "id": "text1556616439",
        "max": 64,
        "min": 0,
        "name": "sha256",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": false,
        "system": false,
        "type": "text"
      },
      {
        "help": "",
        "hidden": false,
        "id": "number1615430137",
        "max": null,
        "min": 0,
        "name": "size_bytes",
        "onlyInt": true,
        "presentable": false,
        "required": false,
        "system": false,
        "type": "number"
      },
      {
        "convertURLs": false,
        "help": "",
        "hidden": false,
        "id": "editor18589324",
        "maxSize": 0,
        "name": "notes",
        "presentable": false,
        "required": false,
        "system": false,
        "type": "editor"
      },
      {
        "help": "",
        "hidden": false,
        "id": "bool1748787223",
        "name": "published",
        "presentable": false,
        "required": false,
        "system": false,
        "type": "bool"
      },
      {
        "help": "",
        "hidden": false,
        "id": "date3772055009",
        "max": "",
        "min": "",
        "name": "published_at",
        "presentable": false,
        "required": false,
        "system": false,
        "type": "date"
      },
      {
        "hidden": false,
        "id": "autodate2990389176",
        "name": "created",
        "onCreate": true,
        "onUpdate": false,
        "presentable": false,
        "system": false,
        "type": "autodate"
      },
      {
        "hidden": false,
        "id": "autodate3332085495",
        "name": "updated",
        "onCreate": true,
        "onUpdate": true,
        "presentable": false,
        "system": false,
        "type": "autodate"
      }
    ]
  },
  {
    "id": "mm_app_config",
    "name": "app_config",
    "type": "base",
    "listRule": "public = true",
    "viewRule": "public = true",
    "createRule": null,
    "updateRule": null,
    "deleteRule": null,
    "indexes": [
      "CREATE UNIQUE INDEX idx_app_config_key ON app_config (key)"
    ],
    "fields": [
      {
        "autogeneratePattern": "[a-z0-9]{15}",
        "help": "",
        "hidden": false,
        "id": "text3208210256",
        "max": 15,
        "min": 15,
        "name": "id",
        "pattern": "^[a-z0-9]+$",
        "presentable": false,
        "primaryKey": true,
        "required": true,
        "system": true,
        "type": "text"
      },
      {
        "autogeneratePattern": "",
        "help": "",
        "hidden": false,
        "id": "text2324736937",
        "max": 100,
        "min": 0,
        "name": "key",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": true,
        "system": false,
        "type": "text"
      },
      {
        "help": "",
        "hidden": false,
        "id": "json494360628",
        "maxSize": 20000,
        "name": "value",
        "presentable": false,
        "required": false,
        "system": false,
        "type": "json"
      },
      {
        "help": "",
        "hidden": false,
        "id": "bool1001664029",
        "name": "public",
        "presentable": false,
        "required": false,
        "system": false,
        "type": "bool"
      },
      {
        "hidden": false,
        "id": "autodate2990389176",
        "name": "created",
        "onCreate": true,
        "onUpdate": false,
        "presentable": false,
        "system": false,
        "type": "autodate"
      },
      {
        "hidden": false,
        "id": "autodate3332085495",
        "name": "updated",
        "onCreate": true,
        "onUpdate": true,
        "presentable": false,
        "system": false,
        "type": "autodate"
      }
    ]
  },
  {
    "id": "mm_audit_log",
    "name": "audit_log",
    "type": "base",
    "listRule": null,
    "viewRule": null,
    "createRule": null,
    "updateRule": null,
    "deleteRule": null,
    "indexes": [
      "CREATE INDEX idx_audit_event ON audit_log (event, created)"
    ],
    "fields": [
      {
        "autogeneratePattern": "[a-z0-9]{15}",
        "help": "",
        "hidden": false,
        "id": "text3208210256",
        "max": 15,
        "min": 15,
        "name": "id",
        "pattern": "^[a-z0-9]+$",
        "presentable": false,
        "primaryKey": true,
        "required": true,
        "system": true,
        "type": "text"
      },
      {
        "autogeneratePattern": "",
        "help": "",
        "hidden": false,
        "id": "text1001261735",
        "max": 60,
        "min": 0,
        "name": "event",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": true,
        "system": false,
        "type": "text"
      },
      {
        "cascadeDelete": false,
        "collectionId": "_pb_users_auth_",
        "help": "",
        "hidden": false,
        "id": "relation2375276105",
        "maxSelect": 1,
        "minSelect": 0,
        "name": "user",
        "presentable": false,
        "required": false,
        "system": false,
        "type": "relation"
      },
      {
        "help": "",
        "hidden": false,
        "id": "json772177811",
        "maxSize": 5000,
        "name": "detail",
        "presentable": false,
        "required": false,
        "system": false,
        "type": "json"
      },
      {
        "hidden": false,
        "id": "autodate2990389176",
        "name": "created",
        "onCreate": true,
        "onUpdate": false,
        "presentable": false,
        "system": false,
        "type": "autodate"
      },
      {
        "hidden": false,
        "id": "autodate3332085495",
        "name": "updated",
        "onCreate": true,
        "onUpdate": true,
        "presentable": false,
        "system": false,
        "type": "autodate"
      }
    ]
  },
  {
    "id": "mm_site_events",
    "name": "site_events",
    "type": "base",
    "listRule": null,
    "viewRule": null,
    "createRule": "@request.body.event != \"\" && @request.body.variant != \"\" && @request.body.visitor != \"\" && @request.body.user:isset = false",
    "updateRule": null,
    "deleteRule": null,
    "indexes": [
      "CREATE INDEX idx_site_events_variant_event ON site_events (variant, event, created)"
    ],
    "fields": [
      {
        "autogeneratePattern": "[a-z0-9]{15}",
        "help": "",
        "hidden": false,
        "id": "text3208210256",
        "max": 15,
        "min": 15,
        "name": "id",
        "pattern": "^[a-z0-9]+$",
        "presentable": false,
        "primaryKey": true,
        "required": true,
        "system": true,
        "type": "text"
      },
      {
        "help": "",
        "hidden": false,
        "id": "select1001261735",
        "maxSelect": 1,
        "name": "event",
        "presentable": false,
        "required": true,
        "system": false,
        "type": "select",
        "values": [
          "view",
          "cta",
          "signup_view",
          "signup",
          "login",
          "redeem",
          "purchase"
        ]
      },
      {
        "autogeneratePattern": "",
        "help": "",
        "hidden": false,
        "id": "text4047749037",
        "max": 20,
        "min": 0,
        "name": "variant",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": true,
        "system": false,
        "type": "text"
      },
      {
        "autogeneratePattern": "",
        "help": "",
        "hidden": false,
        "id": "text3404063135",
        "max": 40,
        "min": 16,
        "name": "visitor",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": true,
        "system": false,
        "type": "text"
      },
      {
        "autogeneratePattern": "",
        "help": "",
        "hidden": false,
        "id": "text190089999",
        "max": 200,
        "min": 0,
        "name": "path",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": false,
        "system": false,
        "type": "text"
      },
      {
        "autogeneratePattern": "",
        "help": "",
        "hidden": false,
        "id": "text3982779751",
        "max": 300,
        "min": 0,
        "name": "referrer",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": false,
        "system": false,
        "type": "text"
      },
      {
        "autogeneratePattern": "",
        "help": "",
        "hidden": false,
        "id": "text782124695",
        "max": 100,
        "min": 0,
        "name": "utm_source",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": false,
        "system": false,
        "type": "text"
      },
      {
        "autogeneratePattern": "",
        "help": "",
        "hidden": false,
        "id": "text3077012563",
        "max": 100,
        "min": 0,
        "name": "utm_medium",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": false,
        "system": false,
        "type": "text"
      },
      {
        "autogeneratePattern": "",
        "help": "",
        "hidden": false,
        "id": "text2047008041",
        "max": 100,
        "min": 0,
        "name": "utm_campaign",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": false,
        "system": false,
        "type": "text"
      },
      {
        "autogeneratePattern": "",
        "help": "",
        "hidden": false,
        "id": "text1181691900",
        "max": 200,
        "min": 0,
        "name": "target",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": false,
        "system": false,
        "type": "text"
      },
      {
        "cascadeDelete": false,
        "collectionId": "_pb_users_auth_",
        "help": "",
        "hidden": false,
        "id": "relation2375276105",
        "maxSelect": 1,
        "minSelect": 0,
        "name": "user",
        "presentable": false,
        "required": false,
        "system": false,
        "type": "relation"
      },
      {
        "hidden": false,
        "id": "autodate2990389176",
        "name": "created",
        "onCreate": true,
        "onUpdate": false,
        "presentable": false,
        "system": false,
        "type": "autodate"
      }
    ]
  },
  {
    "id": "mm_ai_explain",
    "name": "ai_explanations",
    "type": "base",
    "listRule": null,
    "viewRule": null,
    "createRule": null,
    "updateRule": null,
    "deleteRule": null,
    "indexes": [
      "CREATE UNIQUE INDEX idx_ai_explanations_key ON ai_explanations (key)"
    ],
    "fields": [
      {
        "autogeneratePattern": "[a-z0-9]{15}",
        "help": "",
        "hidden": false,
        "id": "text3208210256",
        "max": 15,
        "min": 15,
        "name": "id",
        "pattern": "^[a-z0-9]+$",
        "presentable": false,
        "primaryKey": true,
        "required": true,
        "system": true,
        "type": "text"
      },
      {
        "autogeneratePattern": "",
        "help": "",
        "hidden": false,
        "id": "text2324736937",
        "max": 300,
        "min": 0,
        "name": "key",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": true,
        "system": false,
        "type": "text"
      },
      {
        "autogeneratePattern": "",
        "help": "",
        "hidden": false,
        "id": "text1002749145",
        "max": 40,
        "min": 0,
        "name": "kind",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": true,
        "system": false,
        "type": "text"
      },
      {
        "help": "",
        "hidden": false,
        "id": "json325763347",
        "maxSize": 5000,
        "name": "result",
        "presentable": false,
        "required": false,
        "system": false,
        "type": "json"
      },
      {
        "hidden": false,
        "id": "autodate2990389176",
        "name": "created",
        "onCreate": true,
        "onUpdate": false,
        "presentable": false,
        "system": false,
        "type": "autodate"
      },
      {
        "hidden": false,
        "id": "autodate3332085495",
        "name": "updated",
        "onCreate": true,
        "onUpdate": true,
        "presentable": false,
        "system": false,
        "type": "autodate"
      }
    ]
  },
  {
    "id": "mm_ai_usage",
    "name": "ai_usage",
    "type": "base",
    "listRule": null,
    "viewRule": null,
    "createRule": null,
    "updateRule": null,
    "deleteRule": null,
    "indexes": [
      "CREATE UNIQUE INDEX idx_ai_usage_user_day ON ai_usage (user, day)",
      "CREATE INDEX idx_ai_usage_day ON ai_usage (day)"
    ],
    "fields": [
      {
        "autogeneratePattern": "[a-z0-9]{15}",
        "help": "",
        "hidden": false,
        "id": "text3208210256",
        "max": 15,
        "min": 15,
        "name": "id",
        "pattern": "^[a-z0-9]+$",
        "presentable": false,
        "primaryKey": true,
        "required": true,
        "system": true,
        "type": "text"
      },
      {
        "cascadeDelete": true,
        "collectionId": "_pb_users_auth_",
        "help": "",
        "hidden": false,
        "id": "relation2375276105",
        "maxSelect": 1,
        "minSelect": 0,
        "name": "user",
        "presentable": false,
        "required": true,
        "system": false,
        "type": "relation"
      },
      {
        "autogeneratePattern": "",
        "help": "",
        "hidden": false,
        "id": "text3852478864",
        "max": 10,
        "min": 0,
        "name": "day",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": true,
        "system": false,
        "type": "text"
      },
      {
        "help": "",
        "hidden": false,
        "id": "number2089920066",
        "max": null,
        "min": 0,
        "name": "explain",
        "onlyInt": true,
        "presentable": false,
        "required": false,
        "system": false,
        "type": "number"
      },
      {
        "help": "",
        "hidden": false,
        "id": "number2034467270",
        "max": null,
        "min": 0,
        "name": "review",
        "onlyInt": true,
        "presentable": false,
        "required": false,
        "system": false,
        "type": "number"
      },
      {
        "help": "",
        "hidden": false,
        "id": "number1747380960",
        "max": null,
        "min": 0,
        "name": "ask",
        "onlyInt": true,
        "presentable": false,
        "required": false,
        "system": false,
        "type": "number"
      },
      {
        "help": "",
        "hidden": false,
        "id": "number1726912723",
        "max": null,
        "min": 0,
        "name": "input_tokens",
        "onlyInt": true,
        "presentable": false,
        "required": false,
        "system": false,
        "type": "number"
      },
      {
        "help": "",
        "hidden": false,
        "id": "number2122787687",
        "max": null,
        "min": 0,
        "name": "output_tokens",
        "onlyInt": true,
        "presentable": false,
        "required": false,
        "system": false,
        "type": "number"
      },
      {
        "hidden": false,
        "id": "autodate2990389176",
        "name": "created",
        "onCreate": true,
        "onUpdate": false,
        "presentable": false,
        "system": false,
        "type": "autodate"
      },
      {
        "hidden": false,
        "id": "autodate3332085495",
        "name": "updated",
        "onCreate": true,
        "onUpdate": true,
        "presentable": false,
        "system": false,
        "type": "autodate"
      }
    ]
  },
  {
    "id": "mm_app_secrets",
    "name": "app_secrets",
    "type": "base",
    "listRule": null,
    "viewRule": null,
    "createRule": null,
    "updateRule": null,
    "deleteRule": null,
    "indexes": [
      "CREATE UNIQUE INDEX idx_app_secrets_name ON app_secrets (name)"
    ],
    "fields": [
      {
        "autogeneratePattern": "[a-z0-9]{15}",
        "help": "",
        "hidden": false,
        "id": "text3208210256",
        "max": 15,
        "min": 15,
        "name": "id",
        "pattern": "^[a-z0-9]+$",
        "presentable": false,
        "primaryKey": true,
        "required": true,
        "system": true,
        "type": "text"
      },
      {
        "autogeneratePattern": "",
        "help": "",
        "hidden": false,
        "id": "text1579384326",
        "max": 100,
        "min": 0,
        "name": "name",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": true,
        "system": false,
        "type": "text"
      },
      {
        "autogeneratePattern": "",
        "help": "",
        "hidden": true,
        "id": "text494360628",
        "max": 500,
        "min": 0,
        "name": "value",
        "pattern": "",
        "presentable": false,
        "primaryKey": false,
        "required": true,
        "system": false,
        "type": "text"
      },
      {
        "hidden": false,
        "id": "autodate2990389176",
        "name": "created",
        "onCreate": true,
        "onUpdate": false,
        "presentable": false,
        "system": false,
        "type": "autodate"
      },
      {
        "hidden": false,
        "id": "autodate3332085495",
        "name": "updated",
        "onCreate": true,
        "onUpdate": true,
        "presentable": false,
        "system": false,
        "type": "autodate"
      }
    ]
  }
]
  // On an existing installation preserve collection IDs (relations reference these IDs).
  const ids = {}
  for (const schema of baseline) {
    try { ids[schema.id] = app.findCollectionByNameOrId(schema.name).id } catch (_) { ids[schema.id] = schema.id }
  }
  for (const schema of baseline) {
    schema.id = ids[schema.id]
    for (const field of schema.fields) {
      if (field.type === "relation" && ids[field.collectionId]) field.collectionId = ids[field.collectionId]
    }
  }
  // Auth policy, mail templates, OAuth and token settings belong to deployment config.
  // Preserve the existing built-in users collection rather than resetting those settings.
  app.importCollections(baseline.filter(schema => schema.name !== "users"), false)
}, (app) => {
  // Intentionally non-destructive: do not drop account or recovery data on rollback.
})
