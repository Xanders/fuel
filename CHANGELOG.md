# Changelog

## 0.2.0 — transport adoption preview

Reusable bounded socket engine and process-local limiter, shared by canonical and compatible wire adapters. Adds account/global admission, strict bounded frame assembly, ordered reliable queues and account fanout. Canonical admission no longer invalidates a room connection on a rejected handshake; idle peers continue receiving snapshots. Public canonical wire shapes, PostgreSQL schema and credentials are unchanged.

## 0.1.0 — development preview

Initial Crystal framework: permanent guest identity and owner-confirmed transfers; RAM sessions and four join flows; HTTP/long-poll/WebSocket; persistent results, leaderboards/outcome ratings; optional chat history and Questmetry; dictionary name generation. Initial public API is experimental.
