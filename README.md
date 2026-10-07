# ai_commerce
AI Agent Commerce — 기존 쇼핑몰(가맹점)과 AI 에이전트(ChatGPT, Gemini, Claude 등)를 잇는 B2B 미들웨어(API Gateway).

**상품 데이터 정제·카탈로그 API → 에이전트 결제 중계(외부 PG 브릿지) → 가맹점 OMS 주문 라우팅**

## 설계 문서
| 문서 | 내용 |
|---|---|
| [docs/01-data-model.md](docs/01-data-model.md) | ERD, 상태 머신, 스키마 설계 근거 |
| [db/migration/V1__init_schema.sql](db/migration/V1__init_schema.sql) | PostgreSQL 16 DDL (pgvector, pg_bigm) |
| [docs/02-architecture.md](docs/02-architecture.md) | 기술 스택, 컴포넌트 구조, 핵심 플로우, 규제·장애 대응 |
| [docs/03-api-spec.md](docs/03-api-spec.md) | 에이전트용 상품 검색 / 결제 세션 생성 API 명세 |
