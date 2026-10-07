-- =============================================================================
-- Agentic Commerce Gateway - Initial Schema (PostgreSQL 16, RDS)
--
-- 설계 원칙
--  * 금액: BIGINT minor unit (KRW=원, USD=cent) + ISO-4217 currency. FLOAT/NUMERIC 금지.
--  * 외부 노출 ID: prefix + ULID TEXT (e.g. 'cs_01J9...'). 시간순 정렬, 추측 불가.
--  * 상태값: PG ENUM 대신 TEXT + CHECK (무중단 마이그레이션 용이).
--  * 정합성 핵심 테이블은 version 컬럼으로 낙관적 락.
--  * PII(구매자 연락처/배송지)는 애플리케이션 레벨 envelope 암호화(KMS) 후 BYTEA 저장.
--    조회가 필요한 값은 HMAC-SHA256 blind index(*_hash) 를 별도 보관.
--  * PG/OMS 자격증명은 DB에 저장하지 않고 Secrets Manager ARN만 참조.
--  * 자금 흐름: 플랫폼 MID 결제 → PG 지급대행 잔액 → 하위몰 지급. 금전 사실은 복식부기 원장(ledger_*)이 정본.
--  * 상태 이력/감사 로그는 append-only.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS vector;   -- pgvector (RDS 지원)
CREATE EXTENSION IF NOT EXISTS pg_bigm;  -- 한글 2-gram 부분일치 검색 (RDS 지원)

-- -----------------------------------------------------------------------------
-- 1. Merchant (가맹점)
-- -----------------------------------------------------------------------------
CREATE TABLE merchants (
    id                  TEXT PRIMARY KEY CHECK (id LIKE 'mch\_%'),
    legal_name          TEXT        NOT NULL,
    display_name        TEXT        NOT NULL,
    business_reg_no     TEXT        NOT NULL UNIQUE,          -- 사업자등록번호
    mail_order_reg_no   TEXT,                                  -- 통신판매업 신고번호
    status              TEXT        NOT NULL DEFAULT 'ONBOARDING'
                        CHECK (status IN ('ONBOARDING','ACTIVE','SUSPENDED','TERMINATED')),
    default_currency    CHAR(3)     NOT NULL DEFAULT 'KRW',
    support_contact     JSONB       NOT NULL DEFAULT '{}'::jsonb,
    return_policy       JSONB       NOT NULL DEFAULT '{}'::jsonb, -- 에이전트에 노출할 교환/반품 정책
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 플랫폼(상위몰) PG 계정 (Toss Payments / KG이니시스). 모든 결제는 플랫폼 MID로 승인된다.
-- 정산 채널(merchant_settlement_profiles.payout_channel):
--   PG_PAYOUT   : 대금을 PG 지급대행 잔액에 두고 플랫폼이 지급 지시 (개정 전금법 시행 전 기본값)
--   DIRECT_BANK : PG → 플랫폼 정산 전용 계좌 → 하위몰 계좌 이체
--                 (개정 전금법 2026-12-17 시행: 통신판매중개 부수 정산은 PG업 제외. 법률검토 후 전환)
CREATE TABLE platform_pg_accounts (
    id                      TEXT PRIMARY KEY CHECK (id LIKE 'ppg\_%'),
    pg_provider             TEXT        NOT NULL CHECK (pg_provider IN ('TOSS','INICIS')),
    pg_mid                  TEXT        NOT NULL,
    currency                CHAR(3)     NOT NULL DEFAULT 'KRW',
    credentials_secret_arn  TEXT        NOT NULL,   -- API secret key (Secrets Manager)
    webhook_secret_arn      TEXT,                   -- 웹훅 서명 검증 키
    payout_enabled          BOOLEAN     NOT NULL DEFAULT false, -- 지급대행 계약 여부 (Toss 지급대행 / 이니시스 지급대행)
    is_primary              BOOLEAN     NOT NULL DEFAULT false,
    status                  TEXT        NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','DISABLED')),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (pg_provider, pg_mid)
);
CREATE UNIQUE INDEX uq_platform_pg_primary
    ON platform_pg_accounts (currency) WHERE is_primary AND status = 'ACTIVE';

-- 하위몰 정산 프로필: 지급 채널/수취인 등록 정보 + 수수료/정산주기 정책.
CREATE TABLE merchant_settlement_profiles (
    merchant_id             TEXT PRIMARY KEY REFERENCES merchants(id),
    payout_channel          TEXT        NOT NULL DEFAULT 'PG_PAYOUT' CHECK (payout_channel IN ('PG_PAYOUT','DIRECT_BANK')),
    platform_pg_account_id  TEXT        REFERENCES platform_pg_accounts(id), -- PG_PAYOUT 일 때 필수
    pg_seller_id            TEXT,                   -- PG 지급대행 서브몰/셀러 ID (PG 심사 통과 후 발급)
    kyc_status              TEXT        NOT NULL DEFAULT 'PENDING'
                            CHECK (kyc_status IN ('PENDING','IN_REVIEW','APPROVED','REJECTED','SUSPENDED')),
    bank_code               TEXT        NOT NULL,
    bank_account_enc        BYTEA       NOT NULL,   -- 정산 계좌번호 (envelope 암호화)
    bank_account_last4      TEXT        NOT NULL,
    account_holder_name     TEXT        NOT NULL,   -- 예금주 (사업자명과 일치 검증)
    platform_fee_bps        INT         NOT NULL CHECK (platform_fee_bps BETWEEN 0 AND 10000), -- 판매수수료(VAT 별도)
    settlement_delay_days   INT         NOT NULL DEFAULT 7 CHECK (settlement_delay_days >= 0),  -- 구매확정 후 D+N
    holdback_bps            INT         NOT NULL DEFAULT 0 CHECK (holdback_bps BETWEEN 0 AND 10000), -- 신규/고위험 보류율
    payout_hold             BOOLEAN     NOT NULL DEFAULT false, -- 분쟁/사고 시 지급 정지
    version                 INT         NOT NULL DEFAULT 0,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (platform_pg_account_id, pg_seller_id),
    CHECK (payout_channel <> 'PG_PAYOUT' OR platform_pg_account_id IS NOT NULL)
);

-- 가맹점 OMS(카페24/고도몰/메이크샵/Shopify/자체 Webhook) 연동 정보
CREATE TABLE merchant_oms_connections (
    id                      TEXT PRIMARY KEY CHECK (id LIKE 'oms\_%'),
    merchant_id             TEXT        NOT NULL REFERENCES merchants(id),
    oms_type                TEXT        NOT NULL
                            CHECK (oms_type IN ('CAFE24','GODOMALL','MAKESHOP','SHOPIFY','CUSTOM_WEBHOOK')),
    endpoint_url            TEXT,
    credentials_secret_arn  TEXT        NOT NULL,   -- OAuth refresh token 등
    supports_inventory_push BOOLEAN     NOT NULL DEFAULT false, -- OMS → 플랫폼 재고 웹훅 지원 여부
    inventory_poll_interval INTERVAL,               -- push 미지원 시 폴링 주기
    status                  TEXT        NOT NULL DEFAULT 'ACTIVE'
                            CHECK (status IN ('ACTIVE','AUTH_EXPIRED','DISABLED')),
    last_healthy_at         TIMESTAMPTZ,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_oms_active_per_merchant
    ON merchant_oms_connections (merchant_id) WHERE status <> 'DISABLED';

-- -----------------------------------------------------------------------------
-- 2. Agent Client (AI 에이전트 플랫폼 = API 소비자)
-- -----------------------------------------------------------------------------
CREATE TABLE agent_clients (
    id                  TEXT PRIMARY KEY CHECK (id LIKE 'agt\_%'),
    name                TEXT        NOT NULL UNIQUE,     -- e.g. 'openai-chatgpt'
    oauth_client_id     TEXT        NOT NULL UNIQUE,
    client_secret_hash  TEXT,                            -- argon2id. mTLS/private_key_jwt 사용 시 NULL
    jwks_uri            TEXT,                            -- private_key_jwt 클라이언트 인증
    scopes              TEXT[]      NOT NULL DEFAULT ARRAY['catalog:read'],
    rate_limit_tier     TEXT        NOT NULL DEFAULT 'STANDARD',
    status              TEXT        NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','SUSPENDED')),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 가맹점이 어떤 에이전트에 노출/판매를 허용할지 (opt-in) + 리스크 한도
CREATE TABLE merchant_agent_policies (
    merchant_id         TEXT        NOT NULL REFERENCES merchants(id),
    agent_client_id     TEXT        NOT NULL REFERENCES agent_clients(id),
    catalog_enabled     BOOLEAN     NOT NULL DEFAULT true,
    checkout_enabled    BOOLEAN     NOT NULL DEFAULT false,
    max_order_amount    BIGINT      CHECK (max_order_amount > 0),
    agent_channel_fee_bps INT       NOT NULL DEFAULT 0 CHECK (agent_channel_fee_bps BETWEEN 0 AND 10000), -- 에이전트 채널 추가 수수료
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (merchant_id, agent_client_id)
);

-- -----------------------------------------------------------------------------
-- 3. Catalog (상품)
-- -----------------------------------------------------------------------------
CREATE TABLE catalog_import_jobs (
    id                  TEXT PRIMARY KEY CHECK (id LIKE 'imp\_%'),
    merchant_id         TEXT        NOT NULL REFERENCES merchants(id),
    source_type         TEXT        NOT NULL
                        CHECK (source_type IN ('CSV','XLSX','URL_CRAWL','OMS_API','MANUAL')),
    source_uri          TEXT        NOT NULL,             -- s3://... 원본 보관 (재처리/감사)
    status              TEXT        NOT NULL DEFAULT 'PENDING'
                        CHECK (status IN ('PENDING','PARSING','NORMALIZING','REVIEW_REQUIRED','COMPLETED','FAILED')),
    stats               JSONB       NOT NULL DEFAULT '{}'::jsonb, -- {total, created, updated, rejected}
    error_report_uri    TEXT,
    requested_by        TEXT        NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at         TIMESTAMPTZ
);

CREATE TABLE products (
    id                  TEXT PRIMARY KEY CHECK (id LIKE 'prd\_%'),
    merchant_id         TEXT        NOT NULL REFERENCES merchants(id),
    merchant_product_ref TEXT       NOT NULL,             -- 가맹점 OMS 상품번호
    title               TEXT        NOT NULL,
    description         TEXT,                             -- 정제된 plain text (HTML 제거)
    brand               TEXT,
    gtin                TEXT,                             -- 바코드/GTIN (있을 때만)
    category_path       TEXT[]      NOT NULL DEFAULT '{}',-- 표준 카테고리 ['가구','침대','프레임']
    attributes          JSONB       NOT NULL DEFAULT '{}'::jsonb, -- 카테고리 스키마로 정규화된 스펙
    schema_org          JSONB,                            -- 사전 렌더링한 JSON-LD (Product)
    image_urls          TEXT[]      NOT NULL DEFAULT '{}',
    canonical_url       TEXT,                             -- 원 쇼핑몰 상품 URL
    status              TEXT        NOT NULL DEFAULT 'DRAFT'
                        CHECK (status IN ('DRAFT','ACTIVE','INACTIVE','DELETED')),
    quality_score       SMALLINT    CHECK (quality_score BETWEEN 0 AND 100), -- 정제 품질 (노출 랭킹/검수)
    source_import_job_id TEXT       REFERENCES catalog_import_jobs(id),
    content_hash        TEXT        NOT NULL,             -- 재임베딩 필요 여부 판단
    version             INT         NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (merchant_id, merchant_product_ref)
);
CREATE INDEX idx_products_merchant_status ON products (merchant_id, status);
CREATE INDEX idx_products_category        ON products USING GIN (category_path);
CREATE INDEX idx_products_attributes      ON products USING GIN (attributes jsonb_path_ops);
CREATE INDEX idx_products_title_bigm      ON products USING GIN (title gin_bigm_ops);

-- 판매 단위(SKU). 가격/재고는 variant 레벨.
CREATE TABLE product_variants (
    id                  TEXT PRIMARY KEY CHECK (id LIKE 'var\_%'),
    product_id          TEXT        NOT NULL REFERENCES products(id),
    merchant_id         TEXT        NOT NULL REFERENCES merchants(id), -- 비정규화: 테넌트 필터
    merchant_sku        TEXT        NOT NULL,
    option_values       JSONB       NOT NULL DEFAULT '{}'::jsonb, -- {"color":"화이트","size":"Q"}
    currency            CHAR(3)     NOT NULL DEFAULT 'KRW',
    price_amount        BIGINT      NOT NULL CHECK (price_amount >= 0),       -- 판매가 (VAT 포함)
    list_price_amount   BIGINT      CHECK (list_price_amount >= 0),           -- 정가
    stock_quantity      INT         NOT NULL DEFAULT 0 CHECK (stock_quantity >= 0),   -- OMS 동기화 값
    reserved_quantity   INT         NOT NULL DEFAULT 0 CHECK (reserved_quantity >= 0),-- 체크아웃 홀드
    stock_synced_at     TIMESTAMPTZ,                      -- 재고 신선도 → 에이전트에 노출
    status              TEXT        NOT NULL DEFAULT 'ACTIVE'
                        CHECK (status IN ('ACTIVE','SOLD_OUT','INACTIVE')),
    version             INT         NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (merchant_id, merchant_sku),
    CHECK (reserved_quantity <= stock_quantity)
);
CREATE INDEX idx_variants_product ON product_variants (product_id);
CREATE INDEX idx_variants_price   ON product_variants (merchant_id, price_amount) WHERE status = 'ACTIVE';

-- 벡터 검색용 임베딩. 모델 교체(blue/green) 대비 (product_id, model) 복합키.
-- 차원은 컬럼 타입에 고정되므로 모델 차원이 바뀌면 신규 컬럼/테이블로 마이그레이션.
CREATE TABLE product_embeddings (
    product_id          TEXT        NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    model               TEXT        NOT NULL,             -- e.g. 'titan-embed-text-v2:1024'
    embedding           vector(1024) NOT NULL,
    source_content_hash TEXT        NOT NULL,             -- = products.content_hash 일 때 최신
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (product_id, model)
);
CREATE INDEX idx_product_embeddings_hnsw
    ON product_embeddings USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);

-- -----------------------------------------------------------------------------
-- 4. Checkout Session (에이전트 결제 세션)
--    * 플랫폼 MID 단일 결제 → 1 세션에 여러 하위몰 상품 혼합 가능 (통합 장바구니)
--    * 하위몰별 소계/배송비는 checkout_session_merchants 로 분리 → 결제 완료 시 하위몰별 주문 N건 생성
--    * 생성 시점 가격/수량을 스냅샷하여 이후 상품가 변경과 무관하게 결제 금액 고정
-- -----------------------------------------------------------------------------
CREATE TABLE checkout_sessions (
    id                  TEXT PRIMARY KEY CHECK (id LIKE 'cs\_%'),
    agent_client_id     TEXT        NOT NULL REFERENCES agent_clients(id),
    platform_pg_account_id TEXT     NOT NULL REFERENCES platform_pg_accounts(id),
    status              TEXT        NOT NULL DEFAULT 'OPEN'
                        CHECK (status IN ('OPEN','PAYMENT_PENDING','COMPLETED','EXPIRED','CANCELED','FAILED')),
    currency            CHAR(3)     NOT NULL,
    subtotal_amount     BIGINT      NOT NULL CHECK (subtotal_amount >= 0),
    shipping_amount     BIGINT      NOT NULL DEFAULT 0 CHECK (shipping_amount >= 0),
    discount_amount     BIGINT      NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    total_amount        BIGINT      NOT NULL CHECK (total_amount >= 0),
    -- 구매자 PII (envelope encryption)
    buyer_name_enc      BYTEA,
    buyer_email_enc     BYTEA,
    buyer_phone_enc     BYTEA,
    buyer_phone_hash    TEXT,                             -- blind index (CS 조회용)
    shipping_address_enc BYTEA,
    -- PG 연계
    pg_order_id         TEXT        NOT NULL UNIQUE,      -- PG에 전달하는 주문번호(orderId/merchant_uid)
    checkout_url        TEXT,                             -- 사용자 승인용 호스티드 결제 페이지
    checkout_token_hash TEXT        UNIQUE,               -- URL 내 1회성 토큰의 SHA-256 (원문 미저장)
    -- 에이전트 컨텍스트 (감사/분쟁 대응)
    agent_reference     TEXT,                             -- 에이전트 측 대화/요청 ID
    buyer_consent       JSONB,                            -- 사용자 승인 증적 {method, at, ip_hash, ua}
    idempotency_key     TEXT        NOT NULL,
    expires_at          TIMESTAMPTZ NOT NULL,
    completed_at        TIMESTAMPTZ,
    version             INT         NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (agent_client_id, idempotency_key),
    CHECK (total_amount = subtotal_amount + shipping_amount - discount_amount)
);
CREATE INDEX idx_cs_expiry ON checkout_sessions (expires_at) WHERE status IN ('OPEN','PAYMENT_PENDING');

-- 세션 내 하위몰별 금액 분해. SUM(total_amount) = checkout_sessions.total_amount (애플리케이션 + 대사 배치 검증)
CREATE TABLE checkout_session_merchants (
    checkout_session_id TEXT        NOT NULL REFERENCES checkout_sessions(id),
    merchant_id         TEXT        NOT NULL REFERENCES merchants(id),
    subtotal_amount     BIGINT      NOT NULL CHECK (subtotal_amount >= 0),
    shipping_amount     BIGINT      NOT NULL DEFAULT 0 CHECK (shipping_amount >= 0),
    discount_amount     BIGINT      NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    total_amount        BIGINT      NOT NULL CHECK (total_amount >= 0),
    PRIMARY KEY (checkout_session_id, merchant_id),
    CHECK (total_amount = subtotal_amount + shipping_amount - discount_amount)
);
CREATE INDEX idx_csm_merchant ON checkout_session_merchants (merchant_id);

CREATE TABLE checkout_session_items (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    checkout_session_id TEXT        NOT NULL,
    merchant_id         TEXT        NOT NULL,
    variant_id          TEXT        NOT NULL REFERENCES product_variants(id),
    product_title       TEXT        NOT NULL,             -- 스냅샷
    option_values       JSONB       NOT NULL,             -- 스냅샷
    unit_price_amount   BIGINT      NOT NULL CHECK (unit_price_amount >= 0),
    quantity            INT         NOT NULL CHECK (quantity > 0),
    line_total_amount   BIGINT      NOT NULL,
    CHECK (line_total_amount = unit_price_amount * quantity),
    UNIQUE (checkout_session_id, variant_id),
    FOREIGN KEY (checkout_session_id, merchant_id)
        REFERENCES checkout_session_merchants (checkout_session_id, merchant_id)
);

-- 재고 홀드 원장. variant.reserved_quantity 와 원자적으로 함께 갱신.
CREATE TABLE inventory_reservations (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    variant_id          TEXT        NOT NULL REFERENCES product_variants(id),
    checkout_session_id TEXT        NOT NULL REFERENCES checkout_sessions(id),
    quantity            INT         NOT NULL CHECK (quantity > 0),
    status              TEXT        NOT NULL DEFAULT 'HELD'
                        CHECK (status IN ('HELD','CONSUMED','RELEASED','EXPIRED')),
    expires_at          TIMESTAMPTZ NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (checkout_session_id, variant_id)
);
CREATE INDEX idx_resv_expiry ON inventory_reservations (expires_at) WHERE status = 'HELD';

-- -----------------------------------------------------------------------------
-- 5. Payment / PG Webhook
-- -----------------------------------------------------------------------------
CREATE TABLE payments (
    id                  TEXT PRIMARY KEY CHECK (id LIKE 'pay\_%'),
    checkout_session_id TEXT        NOT NULL REFERENCES checkout_sessions(id),
    platform_pg_account_id TEXT     NOT NULL REFERENCES platform_pg_accounts(id),
    pg_provider         TEXT        NOT NULL,
    pg_payment_key      TEXT        NOT NULL,             -- PG 거래 키 (tid/paymentKey/imp_uid/pi_...)
    method              TEXT,                             -- CARD, EASY_PAY, TRANSFER ...
    status              TEXT        NOT NULL
                        CHECK (status IN ('APPROVED','PARTIAL_CANCELED','CANCELED','FAILED')),
    currency            CHAR(3)     NOT NULL,
    approved_amount     BIGINT      NOT NULL CHECK (approved_amount >= 0),
    canceled_amount     BIGINT      NOT NULL DEFAULT 0 CHECK (canceled_amount >= 0),
    approved_at         TIMESTAMPTZ,
    pg_raw              JSONB,                            -- PG 조회 응답 (allowlist 필드만, 마스킹)
    version             INT         NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (pg_provider, pg_payment_key),
    CHECK (canceled_amount <= approved_amount)
);
-- 세션당 승인 결제는 최대 1건 (이중결제 방지 최후 방어선)
CREATE UNIQUE INDEX uq_payment_approved_per_session
    ON payments (checkout_session_id) WHERE status IN ('APPROVED','PARTIAL_CANCELED');

-- 결제 취소(부분취소 포함). 통합결제이므로 하위몰 주문 단위로 부분취소가 일어난다.
CREATE TABLE payment_cancellations (
    id                  TEXT PRIMARY KEY CHECK (id LIKE 'pcx\_%'),
    payment_id          TEXT        NOT NULL REFERENCES payments(id),
    order_id            TEXT,                             -- FK는 orders 생성 후 추가
    amount              BIGINT      NOT NULL CHECK (amount > 0),
    reason_code         TEXT        NOT NULL,             -- BUYER_CANCEL, OUT_OF_STOCK, MERCHANT_REJECT, RETURN ...
    status              TEXT        NOT NULL DEFAULT 'REQUESTED'
                        CHECK (status IN ('REQUESTED','SUCCEEDED','FAILED')),
    pg_cancel_key       TEXT,                             -- PG 취소 거래 키
    idempotency_key     TEXT        NOT NULL UNIQUE,      -- PG 취소 API 멱등키로도 사용
    requested_by        TEXT        NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at        TIMESTAMPTZ
);
CREATE INDEX idx_pcx_payment ON payment_cancellations (payment_id);

-- 웹훅 수신 원장 (Inbox). 수신 즉시 저장 → 200 응답 → 비동기 처리.
CREATE TABLE pg_webhook_events (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pg_provider         TEXT        NOT NULL,
    dedupe_key          TEXT        NOT NULL,             -- PG event id, 없으면 sha256(payload)
    event_type          TEXT        NOT NULL,             -- 결제 승인/취소, 지급대행 완료/실패 등
    pg_order_id         TEXT,
    signature_verified  BOOLEAN     NOT NULL,
    payload             JSONB       NOT NULL,
    process_status      TEXT        NOT NULL DEFAULT 'RECEIVED'
                        CHECK (process_status IN ('RECEIVED','PROCESSED','IGNORED','FAILED')),
    attempt_count       INT         NOT NULL DEFAULT 0,
    last_error          TEXT,
    received_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at        TIMESTAMPTZ,
    UNIQUE (pg_provider, dedupe_key)
);
CREATE INDEX idx_webhook_pending ON pg_webhook_events (received_at) WHERE process_status IN ('RECEIVED','FAILED');

-- -----------------------------------------------------------------------------
-- 6. Order (하위몰별 주문) & OMS 라우팅
--    1 결제(세션) : N 주문(하위몰별)
-- -----------------------------------------------------------------------------
CREATE TABLE orders (
    id                  TEXT PRIMARY KEY CHECK (id LIKE 'ord\_%'),
    merchant_id         TEXT        NOT NULL REFERENCES merchants(id),
    agent_client_id     TEXT        NOT NULL REFERENCES agent_clients(id),
    checkout_session_id TEXT        NOT NULL REFERENCES checkout_sessions(id),
    payment_id          TEXT        NOT NULL REFERENCES payments(id),
    status              TEXT        NOT NULL DEFAULT 'CREATED'
                        CHECK (status IN ('CREATED','DISPATCHING','ACCEPTED','REJECTED',
                                          'SHIPPED','DELIVERED','PURCHASE_CONFIRMED',
                                          'CANCEL_REQUESTED','CANCELED','RETURN_REQUESTED','RETURNED')),
    currency            CHAR(3)     NOT NULL,
    subtotal_amount     BIGINT      NOT NULL CHECK (subtotal_amount >= 0),
    shipping_amount     BIGINT      NOT NULL DEFAULT 0 CHECK (shipping_amount >= 0),
    discount_amount     BIGINT      NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    total_amount        BIGINT      NOT NULL CHECK (total_amount >= 0),   -- 이 주문에 배분된 결제금액
    refunded_amount     BIGINT      NOT NULL DEFAULT 0 CHECK (refunded_amount >= 0),
    buyer_name_enc      BYTEA,
    buyer_email_enc     BYTEA,
    buyer_phone_enc     BYTEA,
    buyer_phone_hash    TEXT,
    shipping_address_enc BYTEA,
    merchant_order_ref  TEXT,                             -- OMS 발급 주문번호 (전송 성공 후)
    tracking_info       JSONB,                            -- {carrier, tracking_no}
    delivered_at        TIMESTAMPTZ,
    purchase_confirmed_at TIMESTAMPTZ,                    -- 정산 기산일 (구매확정 or 배송완료+N일 자동확정)
    version             INT         NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (checkout_session_id, merchant_id),            -- 세션 x 하위몰 당 주문 1건 보장
    CHECK (total_amount = subtotal_amount + shipping_amount - discount_amount),
    CHECK (refunded_amount <= total_amount)
);
CREATE INDEX idx_orders_merchant_created ON orders (merchant_id, created_at DESC);
CREATE INDEX idx_orders_payment ON orders (payment_id);
CREATE INDEX idx_orders_status ON orders (status) WHERE status IN ('CREATED','DISPATCHING','CANCEL_REQUESTED','RETURN_REQUESTED');
CREATE INDEX idx_orders_auto_confirm ON orders (delivered_at) WHERE status = 'DELIVERED';
CREATE UNIQUE INDEX uq_orders_merchant_ref ON orders (merchant_id, merchant_order_ref) WHERE merchant_order_ref IS NOT NULL;

ALTER TABLE payment_cancellations
    ADD CONSTRAINT fk_pcx_order FOREIGN KEY (order_id) REFERENCES orders(id);

CREATE TABLE order_items (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id            TEXT        NOT NULL REFERENCES orders(id),
    variant_id          TEXT        NOT NULL REFERENCES product_variants(id),
    merchant_sku        TEXT        NOT NULL,             -- OMS 매핑 키 스냅샷
    product_title       TEXT        NOT NULL,
    option_values       JSONB       NOT NULL,
    unit_price_amount   BIGINT      NOT NULL,
    quantity            INT         NOT NULL CHECK (quantity > 0),
    line_total_amount   BIGINT      NOT NULL
);
CREATE INDEX idx_order_items_order ON order_items (order_id);

-- 주문 상태 전이 이력 (append-only, 감사 대상)
CREATE TABLE order_status_history (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id            TEXT        NOT NULL REFERENCES orders(id),
    from_status         TEXT,
    to_status           TEXT        NOT NULL,
    reason              TEXT,
    actor_type          TEXT        NOT NULL CHECK (actor_type IN ('SYSTEM','PG','OMS','AGENT','OPERATOR','BUYER')),
    actor_id            TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_osh_order ON order_status_history (order_id, created_at);

-- OMS 전송 작업 (at-least-once + 재시도/백오프). 1 주문 1 행, 시도 내역은 attempts.
CREATE TABLE order_dispatches (
    order_id            TEXT PRIMARY KEY REFERENCES orders(id),
    oms_connection_id   TEXT        NOT NULL REFERENCES merchant_oms_connections(id),
    status              TEXT        NOT NULL DEFAULT 'PENDING'
                        CHECK (status IN ('PENDING','IN_FLIGHT','SUCCEEDED','RETRYING','DEAD')),
    attempt_count       INT         NOT NULL DEFAULT 0,
    next_attempt_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_error          TEXT,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_dispatch_due ON order_dispatches (next_attempt_at) WHERE status IN ('PENDING','RETRYING');

CREATE TABLE order_dispatch_attempts (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id            TEXT        NOT NULL REFERENCES orders(id),
    attempt_no          INT         NOT NULL,
    http_status         INT,
    request_body        JSONB,                            -- PII 마스킹
    response_body       JSONB,
    error_class         TEXT,                             -- TIMEOUT, AUTH, VALIDATION, OUT_OF_STOCK ...
    latency_ms          INT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (order_id, attempt_no)
);

-- -----------------------------------------------------------------------------
-- 7. Ledger & Settlement (복식부기 원장 / 하위몰 정산 / 지급대행)
--    * ledger_* 는 회계 진실의 원천. 잔액은 entries 합으로만 계산 (잔액 컬럼 UPDATE 금지)
--    * settlement_items: 정산 대상 이벤트(판매/취소/조정) 단위 금액 분해
--    * settlements: 하위몰 x 정산일 단위 집계 → payouts: PG 지급대행 요청
-- -----------------------------------------------------------------------------
CREATE TABLE ledger_accounts (
    id                  TEXT PRIMARY KEY CHECK (id LIKE 'lac\_%'),
    owner_type          TEXT        NOT NULL CHECK (owner_type IN ('PLATFORM','MERCHANT')),
    owner_id            TEXT        NOT NULL,             -- 'platform' 또는 merchant_id
    account_type        TEXT        NOT NULL CHECK (account_type IN (
                            'PG_RECEIVABLE',          -- 자산: PG로부터 받을 결제대금
                            'PAYOUT_BALANCE',         -- 자산: PG 지급대행 잔액(플랫폼 명의, PG 보관) [PG_PAYOUT]
                            'SETTLEMENT_BANK',        -- 자산: 플랫폼 정산 전용 계좌(운영자금과 분리) [DIRECT_BANK]
                            'PG_FEE_EXPENSE',         -- 비용: PG 결제수수료
                            'PLATFORM_FEE_REVENUE',   -- 수익: 판매수수료
                            'VAT_PAYABLE',            -- 부채: 수수료 부가세 예수금
                            'MERCHANT_PAYABLE',       -- 부채: 하위몰 지급 예정액 (차변 잔액 = 하위몰 미수금, 다음 정산에서 상계)
                            'PLATFORM_OPERATING_CASH' -- 자산: 플랫폼 운영계좌 (수수료 인출 대상)
                        )),
    currency            CHAR(3)     NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (owner_type, owner_id, account_type, currency)
);

CREATE TABLE ledger_transactions (
    id                  TEXT PRIMARY KEY CHECK (id LIKE 'ltx\_%'),
    tx_type             TEXT        NOT NULL CHECK (tx_type IN (
                            'ORDER_SALE','PLATFORM_FEE','ORDER_REFUND','PG_FEE','PG_SETTLEMENT_RECEIVED',
                            'PAYOUT','PAYOUT_FAILED_REVERSAL','PLATFORM_FEE_WITHDRAWAL','ADJUSTMENT')),
    reference_type      TEXT        NOT NULL,             -- ORDER, PAYMENT_CANCELLATION, PAYOUT, PG_SETTLEMENT ...
    reference_id        TEXT        NOT NULL,
    description         TEXT,
    occurred_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          TEXT        NOT NULL,             -- SYSTEM 또는 운영자 ID (ADJUSTMENT는 2인 승인)
    UNIQUE (tx_type, reference_type, reference_id)        -- 같은 사건의 이중 분개 방지
);

CREATE TABLE ledger_entries (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id      TEXT        NOT NULL REFERENCES ledger_transactions(id),
    account_id          TEXT        NOT NULL REFERENCES ledger_accounts(id),
    direction           TEXT        NOT NULL CHECK (direction IN ('DEBIT','CREDIT')),
    amount              BIGINT      NOT NULL CHECK (amount > 0),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_ledger_entries_tx ON ledger_entries (transaction_id);
CREATE INDEX idx_ledger_entries_account ON ledger_entries (account_id, id);

-- 분개 대차 일치 강제: 커밋 시점에 트랜잭션별 차변합 = 대변합 검증
CREATE FUNCTION assert_ledger_balanced() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_debit  BIGINT;
    v_credit BIGINT;
BEGIN
    SELECT COALESCE(SUM(amount) FILTER (WHERE direction = 'DEBIT'), 0),
           COALESCE(SUM(amount) FILTER (WHERE direction = 'CREDIT'), 0)
      INTO v_debit, v_credit
      FROM ledger_entries
     WHERE transaction_id = NEW.transaction_id;
    IF v_debit <> v_credit THEN
        RAISE EXCEPTION 'ledger transaction % unbalanced (debit=%, credit=%)',
            NEW.transaction_id, v_debit, v_credit;
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER trg_ledger_balanced
    AFTER INSERT ON ledger_entries
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION assert_ledger_balanced();

-- 원장은 append-only: 정정은 반대 분개(ADJUSTMENT)로만
CREATE FUNCTION forbid_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% is append-only', TG_TABLE_NAME;
END $$;
CREATE TRIGGER trg_ledger_entries_immutable BEFORE UPDATE OR DELETE ON ledger_entries
    FOR EACH ROW EXECUTE FUNCTION forbid_mutation();
CREATE TRIGGER trg_ledger_transactions_immutable BEFORE UPDATE OR DELETE ON ledger_transactions
    FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

-- 정산 대상 항목: 판매(+) / 취소·반품(-) / 조정(±)
CREATE TABLE settlement_items (
    id                  TEXT PRIMARY KEY CHECK (id LIKE 'sti\_%'),
    merchant_id         TEXT        NOT NULL REFERENCES merchants(id),
    order_id            TEXT        NOT NULL REFERENCES orders(id),
    item_type           TEXT        NOT NULL CHECK (item_type IN ('SALE','REFUND','ADJUSTMENT')),
    source_ref          TEXT        NOT NULL,             -- order_id / payment_cancellation_id / adjustment id
    currency            CHAR(3)     NOT NULL,
    gross_amount        BIGINT      NOT NULL,             -- 판매대금 (REFUND 는 음수)
    platform_fee_amount BIGINT      NOT NULL,             -- 판매수수료 (VAT 별도, REFUND 는 음수)
    platform_fee_vat_amount BIGINT  NOT NULL,             -- 수수료 부가세
    net_amount          BIGINT      NOT NULL,             -- 하위몰 지급액 = gross - fee - vat
    fee_bps_applied     INT         NOT NULL,             -- 적용 수수료율 스냅샷 (정책 변경과 무관하게 재현)
    status              TEXT        NOT NULL DEFAULT 'PENDING'
                        CHECK (status IN ('PENDING','ELIGIBLE','INCLUDED','PAID','HELD','VOID')),
    settle_on           DATE,                             -- 정산 예정일 (구매확정일 + settlement_delay_days, 영업일 보정)
    settlement_id       TEXT,                             -- 포함된 정산 배치
    ledger_transaction_id TEXT      REFERENCES ledger_transactions(id),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (item_type, source_ref),                       -- 동일 사건 이중 정산 방지
    CHECK (net_amount = gross_amount - platform_fee_amount - platform_fee_vat_amount)
);
CREATE INDEX idx_sti_eligible ON settlement_items (merchant_id, settle_on) WHERE status = 'ELIGIBLE';
CREATE INDEX idx_sti_order ON settlement_items (order_id);

-- 하위몰 x 정산일 집계. 음수 정산(환불 과다)은 다음 회차로 이월.
CREATE TABLE settlements (
    id                  TEXT PRIMARY KEY CHECK (id LIKE 'stl\_%'),
    merchant_id         TEXT        NOT NULL REFERENCES merchants(id),
    settle_on           DATE        NOT NULL,
    currency            CHAR(3)     NOT NULL,
    gross_amount        BIGINT      NOT NULL,
    platform_fee_amount BIGINT      NOT NULL,
    platform_fee_vat_amount BIGINT  NOT NULL,
    carried_over_amount BIGINT      NOT NULL DEFAULT 0,   -- 직전 회차 음수 잔액 이월분 (<= 0)
    holdback_amount     BIGINT      NOT NULL DEFAULT 0 CHECK (holdback_amount >= 0),
    payout_amount       BIGINT      NOT NULL CHECK (payout_amount >= 0),
    status              TEXT        NOT NULL DEFAULT 'DRAFT'
                        CHECK (status IN ('DRAFT','CONFIRMED','PAYOUT_REQUESTED','PAID','PAYOUT_FAILED','ON_HOLD','CARRIED_OVER')),
    confirmed_at        TIMESTAMPTZ,
    version             INT         NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (merchant_id, settle_on, currency)
);
ALTER TABLE settlement_items
    ADD CONSTRAINT fk_sti_settlement FOREIGN KEY (settlement_id) REFERENCES settlements(id);

-- 지급 요청 (PG 지급대행 또는 은행 이체).
-- PG 지급대행 잔액은 PG별로 분리되므로 settlement x 지급원(PG 계정 또는 은행) 당 진행/성공 지급 1건.
CREATE TABLE payouts (
    id                  TEXT PRIMARY KEY CHECK (id LIKE 'po\_%'),
    settlement_id       TEXT        NOT NULL REFERENCES settlements(id),
    merchant_id         TEXT        NOT NULL REFERENCES merchants(id),
    payout_channel      TEXT        NOT NULL CHECK (payout_channel IN ('PG_PAYOUT','DIRECT_BANK')),
    platform_pg_account_id TEXT     REFERENCES platform_pg_accounts(id), -- PG_PAYOUT
    payee_ref           TEXT        NOT NULL,             -- pg_seller_id 또는 계좌 토큰 (요청 시점 스냅샷)
    amount              BIGINT      NOT NULL CHECK (amount > 0),
    currency            CHAR(3)     NOT NULL,
    status              TEXT        NOT NULL DEFAULT 'REQUESTED'
                        CHECK (status IN ('REQUESTED','PROCESSING','COMPLETED','FAILED','CANCELED')),
    external_payout_id  TEXT        UNIQUE,               -- PG 지급 ID / 펌뱅킹 거래번호
    idempotency_key     TEXT        NOT NULL UNIQUE,      -- 지급 API 멱등키 (= payout id)
    failure_code        TEXT,                             -- 계좌오류, 예금주 불일치, 잔액부족 ...
    requested_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at        TIMESTAMPTZ
);
CREATE UNIQUE INDEX uq_payout_active_per_settlement
    ON payouts (settlement_id, COALESCE(platform_pg_account_id, 'DIRECT_BANK'))
    WHERE status IN ('REQUESTED','PROCESSING','COMPLETED');

-- PG 정산 데이터 (대사용). PG 정산 API/파일 적재.
CREATE TABLE pg_settlement_records (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    platform_pg_account_id TEXT     NOT NULL REFERENCES platform_pg_accounts(id),
    pg_payment_key      TEXT        NOT NULL,
    transaction_type    TEXT        NOT NULL CHECK (transaction_type IN ('APPROVAL','CANCEL')),
    transaction_ref     TEXT        NOT NULL,             -- 승인/취소 거래 고유키
    amount              BIGINT      NOT NULL,
    pg_fee_amount       BIGINT      NOT NULL,
    pg_fee_vat_amount   BIGINT      NOT NULL DEFAULT 0,
    settle_amount       BIGINT      NOT NULL,             -- PG 입금액 (지급대행 잔액 또는 정산 전용 계좌)
    settle_on           DATE        NOT NULL,
    reconcile_status    TEXT        NOT NULL DEFAULT 'UNMATCHED'
                        CHECK (reconcile_status IN ('UNMATCHED','MATCHED','MISMATCHED','RESOLVED')),
    loaded_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (platform_pg_account_id, transaction_type, transaction_ref)
);
CREATE INDEX idx_pgsr_unmatched ON pg_settlement_records (settle_on) WHERE reconcile_status IN ('UNMATCHED','MISMATCHED');

-- -----------------------------------------------------------------------------
-- 8. Cross-cutting: Idempotency / Outbox / Audit
-- -----------------------------------------------------------------------------
CREATE TABLE idempotency_keys (
    agent_client_id     TEXT        NOT NULL REFERENCES agent_clients(id),
    idempotency_key     TEXT        NOT NULL,
    request_method      TEXT        NOT NULL,
    request_path        TEXT        NOT NULL,
    request_hash        TEXT        NOT NULL,             -- 같은 키 + 다른 바디 → 422
    response_status     INT,                              -- NULL = 처리 중 (409 반환)
    response_body       JSONB,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at          TIMESTAMPTZ NOT NULL DEFAULT now() + INTERVAL '24 hours',
    PRIMARY KEY (agent_client_id, idempotency_key)
);
CREATE INDEX idx_idem_expiry ON idempotency_keys (expires_at);

-- Transactional Outbox → relay가 SQS로 발행 (DB 커밋과 이벤트 발행의 원자성)
CREATE TABLE outbox_events (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    aggregate_type      TEXT        NOT NULL,             -- ORDER, CHECKOUT_SESSION, SETTLEMENT, PAYOUT ...
    aggregate_id        TEXT        NOT NULL,
    event_type          TEXT        NOT NULL,             -- order.created, payment.approved ...
    payload             JSONB       NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at        TIMESTAMPTZ
);
CREATE INDEX idx_outbox_unpublished ON outbox_events (id) WHERE published_at IS NULL;

-- 감사 로그 (append-only, 월 파티션). 운영자 PII 열람/설정 변경/환불 등 기록.
CREATE TABLE audit_logs (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY,
    occurred_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    actor_type          TEXT        NOT NULL,             -- AGENT, MERCHANT_USER, OPERATOR, SYSTEM
    actor_id            TEXT        NOT NULL,
    action              TEXT        NOT NULL,             -- e.g. 'order.refund', 'pii.view'
    target_type         TEXT        NOT NULL,
    target_id           TEXT        NOT NULL,
    request_id          TEXT,                             -- trace 연계
    source_ip           INET,
    detail              JSONB,                            -- before/after (마스킹)
    PRIMARY KEY (id, occurred_at)
) PARTITION BY RANGE (occurred_at);
CREATE TABLE audit_logs_2026_10 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
-- 이후 파티션은 pg_partman 또는 배치로 선생성. 애플리케이션 계정에는 INSERT 권한만 부여.
