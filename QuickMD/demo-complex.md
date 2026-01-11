# System Architecture Overview

> **Project Apollo** - Distributed Microservices Platform
> Status: Production | Version: 2.4.0 | Last Updated: 2026-01-11

---

## 📊 Performance Metrics Dashboard

| Service | Latency (p95) | Throughput | CPU Usage | Memory | Status |
|---------|---------------|------------|-----------|--------|--------|
| API Gateway | 12ms | 45K req/s | 34% | 2.1GB | ✅ Healthy |
| Auth Service | 8ms | 12K req/s | 28% | 1.4GB | ✅ Healthy |
| User Service | 15ms | 8K req/s | 42% | 3.2GB | ⚠️ Warning |
| Payment Service | 45ms | 2K req/s | 18% | 1.8GB | ✅ Healthy |
| Analytics Engine | 120ms | 500 req/s | 67% | 8.4GB | ⚠️ Warning |
| Notification Hub | 25ms | 15K req/s | 31% | 2.6GB | ✅ Healthy |
| Database Cluster | 3ms | 100K queries/s | 56% | 16GB | ✅ Healthy |

---

## 🎯 Implementation Roadmap

### Phase 1: Infrastructure ✅
- [x] Kubernetes cluster setup (3 zones, 45 nodes)
- [x] Load balancer configuration (HAProxy + Nginx)
- [x] SSL/TLS certificates (Let's Encrypt)
- [x] Monitoring stack (Prometheus + Grafana)
    - [x] Custom dashboards for each service
    - [x] Alert rules for SLO violations
    - [x] PagerDuty integration
- [x] CI/CD pipelines (GitHub Actions)
    - [x] Automated testing suite
    - [x] Security scanning (Snyk + SonarQube)
    - [x] Blue-green deployments

### Phase 2: Core Services 🔄
- [x] User authentication (OAuth 2.0 + JWT)
- [x] API rate limiting (Redis-based)
- [x] Database migrations (Flyway)
- [ ] Real-time notifications (WebSockets)
    - [x] Infrastructure setup
    - [ ] Client SDK implementation
    - [ ] Load testing (target: 100K concurrent connections)
- [ ] GraphQL federation layer
    - [x] Schema design
    - [ ] Resolver implementation
    - [ ] Performance optimization

### Phase 3: Advanced Features 📋
- [ ] Machine learning recommendations
- [ ] Multi-region replication
- [ ] Chaos engineering testing
- [ ] Service mesh migration (Istio)

---

## 💻 Code Examples

### 1. API Gateway Configuration

```typescript
import { FastifyInstance } from 'fastify';
import { authenticate } from './middleware/auth';
import { rateLimit } from './middleware/ratelimit';

export async function routes(server: FastifyInstance) {
  // Health check endpoint
  server.get('/health', async (request, reply) => {
    return { status: 'ok', timestamp: Date.now() };
  });

  // Protected user routes
  server.register(async (userRoutes) => {
    userRoutes.addHook('preHandler', authenticate);

    userRoutes.get('/users/:id', async (request, reply) => {
      const { id } = request.params as { id: string };
      const user = await userService.findById(id);

      if (!user) {
        return reply.code(404).send({ error: 'User not found' });
      }

      return user;
    });

    userRoutes.post('/users', {
      preHandler: rateLimit({ max: 10, window: '1m' })
    }, async (request, reply) => {
      const userData = request.body as CreateUserDTO;
      const newUser = await userService.create(userData);

      return reply.code(201).send(newUser);
    });
  }, { prefix: '/api/v1' });
}
```

### 2. Database Query Optimization

```sql
-- Before: Slow nested subquery (2.3s)
SELECT u.id, u.name, u.email,
       (SELECT COUNT(*) FROM orders WHERE user_id = u.id) as order_count,
       (SELECT SUM(total) FROM orders WHERE user_id = u.id) as total_spent
FROM users u
WHERE u.created_at > NOW() - INTERVAL '30 days';

-- After: Optimized with JOIN and aggregation (45ms)
SELECT u.id, u.name, u.email,
       COALESCE(o.order_count, 0) as order_count,
       COALESCE(o.total_spent, 0) as total_spent
FROM users u
LEFT JOIN (
    SELECT user_id,
           COUNT(*) as order_count,
           SUM(total) as total_spent
    FROM orders
    WHERE created_at > NOW() - INTERVAL '30 days'
    GROUP BY user_id
) o ON u.id = o.user_id
WHERE u.created_at > NOW() - INTERVAL '30 days';

-- Indexes for optimal performance
CREATE INDEX CONCURRENTLY idx_users_created_at ON users(created_at);
CREATE INDEX CONCURRENTLY idx_orders_user_created ON orders(user_id, created_at);
```

### 3. Redis Caching Strategy

```python
import redis
import json
from typing import Optional, Dict, Any
from functools import wraps

class CacheManager:
    def __init__(self, host: str = 'localhost', port: int = 6379):
        self.client = redis.Redis(
            host=host,
            port=port,
            decode_responses=True,
            socket_connect_timeout=5
        )

    def cached(self, ttl: int = 3600, key_prefix: str = ''):
        """Decorator for caching function results"""
        def decorator(func):
            @wraps(func)
            async def wrapper(*args, **kwargs):
                # Generate cache key from function name and arguments
                cache_key = f"{key_prefix}:{func.__name__}:{hash(str(args) + str(kwargs))}"

                # Try to get from cache
                cached_value = self.client.get(cache_key)
                if cached_value:
                    return json.loads(cached_value)

                # Execute function and cache result
                result = await func(*args, **kwargs)
                self.client.setex(cache_key, ttl, json.dumps(result))

                return result
            return wrapper
        return decorator

    def invalidate_pattern(self, pattern: str) -> int:
        """Invalidate all keys matching pattern"""
        keys = self.client.keys(pattern)
        if keys:
            return self.client.delete(*keys)
        return 0

# Usage example
cache = CacheManager()

@cache.cached(ttl=1800, key_prefix='user')
async def get_user_profile(user_id: int) -> Dict[str, Any]:
    # Expensive database query
    user = await db.query(
        "SELECT * FROM users WHERE id = $1", user_id
    )
    return user
```

### 4. Kubernetes Deployment Config

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-gateway
  namespace: production
  labels:
    app: api-gateway
    version: v2.4.0
spec:
  replicas: 10
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 3
      maxUnavailable: 1
  selector:
    matchLabels:
      app: api-gateway
  template:
    metadata:
      labels:
        app: api-gateway
        version: v2.4.0
    spec:
      containers:
      - name: api-gateway
        image: registry.example.com/api-gateway:2.4.0
        ports:
        - containerPort: 3000
          name: http
        - containerPort: 9090
          name: metrics
        env:
        - name: NODE_ENV
          value: "production"
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: db-credentials
              key: connection-string
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
        livenessProbe:
          httpGet:
            path: /health
            port: 3000
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /ready
            port: 3000
          initialDelaySeconds: 15
          periodSeconds: 5
```

---

## 🔧 Configuration Matrix

| Environment | Database | Cache | CDN | Region | Auto-Scale |
|-------------|----------|-------|-----|--------|------------|
| **Development** | PostgreSQL 15 | Redis 7 | Disabled | us-west-1 | No |
| **Staging** | PostgreSQL 15 (HA) | Redis Cluster | CloudFront | us-west-1, us-east-1 | Yes (2-5 nodes) |
| **Production** | PostgreSQL 15 (HA) | Redis Cluster | CloudFront + Fastly | Multi-region (5 zones) | Yes (10-50 nodes) |

---

## 📈 Analytics Query Examples

```go
package analytics

import (
    "context"
    "time"
    "github.com/clickhouse/clickhouse-go/v2"
)

type AnalyticsEngine struct {
    conn clickhouse.Conn
}

// GetUserEngagement calculates user engagement metrics
func (a *AnalyticsEngine) GetUserEngagement(ctx context.Context, days int) ([]Metric, error) {
    query := `
        SELECT
            toStartOfDay(timestamp) as date,
            COUNT(DISTINCT user_id) as active_users,
            COUNT(*) as total_events,
            AVG(session_duration) as avg_session_duration,
            quantile(0.95)(response_time) as p95_response_time
        FROM events
        WHERE timestamp >= now() - INTERVAL ? DAY
        AND event_type IN ('page_view', 'click', 'purchase')
        GROUP BY date
        ORDER BY date DESC
    `

    rows, err := a.conn.Query(ctx, query, days)
    if err != nil {
        return nil, err
    }
    defer rows.Close()

    var metrics []Metric
    for rows.Next() {
        var m Metric
        if err := rows.Scan(&m.Date, &m.ActiveUsers, &m.TotalEvents,
                           &m.AvgSessionDuration, &m.P95ResponseTime); err != nil {
            return nil, err
        }
        metrics = append(metrics, m)
    }

    return metrics, nil
}

type Metric struct {
    Date               time.Time
    ActiveUsers        int64
    TotalEvents        int64
    AvgSessionDuration float64
    P95ResponseTime    float64
}
```

---

## 🚀 Deployment Commands

```bash
#!/bin/bash

# Build and push Docker image
docker build -t registry.example.com/api-gateway:2.4.0 .
docker push registry.example.com/api-gateway:2.4.0

# Deploy to Kubernetes
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/ingress.yaml

# Wait for rollout
kubectl rollout status deployment/api-gateway -n production

# Run smoke tests
curl -f https://api.example.com/health || exit 1
curl -f https://api.example.com/ready || exit 1

# Monitor deployment
kubectl get pods -n production -l app=api-gateway -w
```

---

## 📊 Cost Analysis

| Component | Monthly Cost | Annual Cost | Cost/User | Optimization Potential |
|-----------|--------------|-------------|-----------|------------------------|
| **Compute (EC2)** | $12,450 | $149,400 | $0.012 | 15% (reserved instances) |
| **Database (RDS)** | $8,900 | $106,800 | $0.009 | 10% (storage optimization) |
| **Cache (ElastiCache)** | $2,340 | $28,080 | $0.002 | 5% (instance rightsizing) |
| **CDN (CloudFront)** | $3,670 | $44,040 | $0.004 | 20% (compression + caching) |
| **Monitoring** | $1,200 | $14,400 | $0.001 | Minimal |
| **Data Transfer** | $4,500 | $54,000 | $0.005 | 30% (regional optimization) |
| **Total** | **$33,060** | **$396,720** | **$0.033** | **18% overall** |

> **Note:** Based on 1M monthly active users. Costs decrease with scale due to volume discounts.

---

**Built with ❤️ by the Platform Engineering Team**
*Last deployment: 2026-01-11 22:30 UTC | Next review: 2026-01-18*
