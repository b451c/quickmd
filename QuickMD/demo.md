# Stellar Framework

A next-generation **Swift** framework for building high-performance backend services.

> Stellar is designed for developers who value **speed**, **simplicity**, and **type safety**. Built entirely in Swift, it leverages async/await and structured concurrency.

## Getting Started

Install Stellar via [Swift Package Manager][spm]:

```swift
dependencies: [
    .package(url: "https://github.com/stellar/stellar", from: "3.0.0")
]
```

Create your first API in under 30 seconds:

```swift
import Stellar

@main
struct MyApp: StellarApp {
    var routes: some Route {
        GET("/hello") { req in
            return Response(status: .ok, body: "Hello, World!")
        }

        Group("api/v1") {
            GET("/users") { req in
                let users = try await User.query(on: req.db).all()
                return users.map { $0.toDTO() }
            }

            POST("/users") { req in
                let input = try req.decode(CreateUserInput.self)
                let user = User(name: input.name, email: input.email)
                try await user.save(on: req.db)
                return Response(status: .created, body: user.toDTO())
            }

            DELETE("/users/:id") { req in
                guard let user = try await User.find(req.params.id, on: req.db) else {
                    throw Abort(.notFound, reason: "User not found")
                }
                try await user.delete(on: req.db)
                return Response(status: .noContent)
            }
        }
    }
}
```

## Architecture

Stellar follows a **modular architecture** with clear separation of concerns:

### Core Modules

| Module | Description | Dependencies |
|--------|-------------|-------------|
| `StellarCore` | Routing, middleware, request/response | Swift NIO |
| `StellarORM` | Database abstraction with migrations | StellarCore |
| `StellarAuth` | JWT authentication & OAuth2 | StellarCore |
| `StellarCache` | Redis & in-memory caching | StellarCore |
| `StellarWebSocket` | Real-time WebSocket support | Swift NIO |

### Performance Benchmarks

| Framework | Requests/sec | Avg Latency | Memory |
|-----------|-------------|-------------|--------|
| **Stellar 3.0** | **185,240** | **0.9ms** | **18 MB** |
| Vapor 4.x | 142,500 | 1.2ms | 24 MB |
| Hummingbird | 168,300 | 1.0ms | 20 MB |
| Express.js | 52,100 | 3.8ms | 85 MB |
| FastAPI | 48,700 | 4.1ms | 62 MB |

## Configuration

Stellar uses a layered configuration system:

```yaml
# stellar.yml
server:
  host: 0.0.0.0
  port: 8080
  workers: auto

database:
  driver: postgresql
  host: localhost
  port: 5432
  name: stellar_db
  pool:
    min: 2
    max: 10

cache:
  driver: redis
  url: redis://localhost:6379
  ttl: 3600

logging:
  level: info
  format: json
```

## Middleware

Build custom middleware with a simple, composable API:

```swift
struct RateLimiter: Middleware {
    let maxRequests: Int
    let window: Duration

    func handle(_ req: Request, next: Next) async throws -> Response {
        let key = "rate:\(req.remoteAddress)"
        let count = try await req.cache.increment(key)

        if count == 1 {
            try await req.cache.expire(key, after: window)
        }

        guard count <= maxRequests else {
            throw Abort(.tooManyRequests, reason: "Rate limit exceeded")
        }

        return try await next.handle(req)
    }
}
```

## Roadmap

### Completed

- [x] Core routing engine with type-safe parameters
- [x] Async middleware pipeline
- [x] PostgreSQL & SQLite drivers
- [x] JWT authentication
- [x] WebSocket support
- [x] OpenAPI spec generation

### In Progress

- [ ] GraphQL integration
- [ ] gRPC support
- [ ] Distributed tracing (OpenTelemetry)

### Planned

- [ ] Server-Sent Events
- [ ] Built-in admin dashboard
- [ ] Plugin marketplace

## Deployment

> **Tip:** Stellar apps can be deployed anywhere Swift runs — Linux, macOS, Docker, and all major cloud providers.

> > **Docker recommended:** For production, we strongly recommend using the official Docker image. It includes all dependencies pre-configured and supports both ARM64 and AMD64 architectures.

> > > See the [deployment guide][deploy] for detailed instructions on AWS, GCP, and Azure.

### Docker

```dockerfile
FROM swift:5.9-jammy as builder
WORKDIR /app
COPY . .
RUN swift build -c release

FROM swift:5.9-jammy-slim
COPY --from=builder /app/.build/release/MyApp /usr/local/bin/
EXPOSE 8080
CMD ["MyApp"]
```

## Community

Join the growing Stellar community:

- **GitHub:** Star the [repository][repo] and contribute
- **Discord:** Chat with other developers on [Discord][discord]
- **Twitter:** Follow [@stellarswift][twitter] for updates
- **Blog:** Read the latest posts on the [Stellar blog][blog]

---

**Stellar** is open source under the [MIT License][license]. Built with Swift.

[spm]: https://swift.org/package-manager/
[deploy]: https://stellar.dev/docs/deployment
[repo]: https://github.com/stellar/stellar
[discord]: https://discord.gg/stellar
[twitter]: https://twitter.com/stellarswift
[blog]: https://stellar.dev/blog
[license]: https://opensource.org/licenses/MIT
