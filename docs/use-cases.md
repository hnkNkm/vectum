# 想定ユースケース

## Webhook Aggregation

GitHub、GitLab、Stripe、監視システム、自社サービスなどから Webhook を一箇所で受信し、複数システムへ配送する。

```text
GitHub ───┐
GitLab ───┤
Stripe ───┤
Monitor ──┤
          ▼
     Event Router
      ├──▶ CI
      ├──▶ Internal API
      ├──▶ Audit
      └──▶ Notification
```

各サービスが個別に retry、timeout、fan-out、logging を実装する必要をなくす。

## On-Premise System Integration

販売管理、在庫管理、物流、会計、CRM、製造管理など、複数のオンプレミスシステム間の Event Routing に利用する。

```text
Sales System
     │
     │ order.created
     ▼
 Event Router
  ├──▶ Inventory
  ├──▶ Logistics
  └──▶ CRM
```

各システム同士を Point-to-Point で直接接続する構成を避ける。

## Factory / Edge Integration

工場、店舗、支店、エッジ拠点などで Event Gateway として利用する。MQTT Adapter は将来拡張。

```text
PLC / IoT Gateway
       │
       ▼
   Event Router
    ├──▶ MES
    ├──▶ Historian
    ├──▶ Alert
    └──▶ Cloud API
```

## Lightweight Event Bus for Microservices

Kafka 等を導入するほどではない小〜中規模のマイクロサービスで利用する。Producer は Consumer の存在を認識せず、Event の発行だけを行う。

```text
Order / Payment / Inventory
              │
              ▼
        Event Router
         ├──▶ Notification
         ├──▶ Analytics
         └──▶ Audit
```

## Monitoring and Alert Routing

Prometheus、Zabbix、Kubernetes、UPS、Network Monitor 等から受信した Event を severity に応じて振り分ける。

```text
Monitoring Systems
       │
       ▼
   Event Router
    ├── critical ─▶ Incident System
    ├── warning  ─▶ Notification
    └── info     ─▶ Log Storage
```

## Cloud / On-Premise Bridge

Cloud と On-Premise の境界に配置し、接続先を集約する。

```text
Cloud
  │
  ▼
DMZ Event Router
  ├──▶ ERP
  ├──▶ Factory System
  └──▶ Internal API
```
