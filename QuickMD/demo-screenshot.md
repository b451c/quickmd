# Project Apollo 🚀

A modern Swift framework for building blazing-fast APIs.

## Quick Start

```swift
import Apollo

@main
struct MyAPI: ApolloApp {
    var routes: some Route {
        GET("/hello") { req in
            return "Hello, World!"
        }

        POST("/users") { req in
            let user = try req.decode(User.self)
            return user.save()
        }
    }
}
```

## Features

| Feature | Status | Performance |
|---------|--------|-------------|
| Async/Await | ✅ Native | 2.3ms |
| JSON Parsing | ✅ Codable | 0.8ms |
| WebSockets | ✅ Built-in | Real-time |
| Database | ✅ PostgreSQL | Pooled |

## Roadmap

- [x] Core routing engine
- [x] Middleware support
- [x] Request validation
- [ ] GraphQL integration
- [ ] Redis caching

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/apollo/apollo", from: "2.0.0")
]
```

> **Note:** Requires Swift 5.9+ and macOS 14+

## Benchmarks

```
Requests/sec:    142,847
Latency (avg):   1.2ms
Memory:          24MB
```

---

Built with ❤️ by the Apollo Team • [Documentation](https://apollo.dev) • MIT License
