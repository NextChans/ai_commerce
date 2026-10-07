# 04. Settlement Design (플랫폼 수취 → 하위몰 정산)

> 관련 DDL: `db/migration/V1__init_schema.sql` §1(platform_pg_accounts, merchant_settlement_profiles), §5(payments, payment_cancellations), §7(ledger_*, settlement_items, settlements, payouts, pg_settlement_records)

## 1. 결정 요약

| 항목 | 결정 |
|---|---|
| 결제 주체 | **플랫폼(상위몰) MID** 단일 결제. PG는 **Toss Payments + KG이니시스** 이중화 (PortOne·Stripe 미사용) |
| 장바구니 | 통합 장바구니 허용: 1 결제 = N 하위몰. 결제 완료 시 하위몰별 주문 N건으로 분리 |
| 정산 지급 채널 | `PG_PAYOUT`(Toss 지급대행 / 이니시스 지급대행) ↔ `DIRECT_BANK`(플랫폼 정산 전용 계좌 → 이체). 하위몰 단위로 전환 가능 |
| 금전 정본 | **복식부기 원장**(`ledger_*`). 잔액 컬럼 없음. 대차 일치·append-only를 DB 트리거로 강제 |
| 정산 기산 | 구매확정(명시적 확정 또는 배송완료 + N일 자동확정) 후 D+`settlement_delay_days` 영업일 |
| 수수료 | 판매수수료 `platform_fee_bps`(VAT 별도) 하위몰 부담, PG 결제수수료는 플랫폼 부담 |

## 2. 규제 프레임과 단계 전략

**개정 전자금융거래법 (2026-12-17 시행)**: PG 정의에서 *"통신판매중개 등 다른 업무를 하면서 부수적으로 대가를 받아 정산을 대행하는 경우"*를 제외합니다. 이커머스 플랫폼의 자체 정산은 PG 등록 없이 할 수 있게 됩니다. 반대로 PG업자에게는 정산자금 외부관리 의무(예치·신탁·지급보증보험)가 새로 생깁니다.

| 단계 | 기간 | 지급 채널 | 근거 |
|---|---|---|---|
| Phase 1 | ~ 2026-12-16 (시행 전) | `PG_PAYOUT` | 개정 전 법이 적용됨. 대금은 PG(등록업자)가 보관하고 플랫폼은 지급만 지시. 현행법상 가장 안전 |
| Phase 2 | 2026-12-17 ~ (법률의견 확보 후) | `DIRECT_BANK` 선택 가능 | 통신판매중개 부수 정산 예외 적용. 지급대행 수수료 절감, 정산 주기·UX 자유도 |

**법무 확인이 꼭 필요한 항목** (설계상 가정이며 법률 판단이 아님):
1. **"부수적" 요건 충족 여부.** 이 플랫폼의 본업이 *결제 중계·정산 자체*로 보이면 예외가 적용되지 않을 수 있습니다. 통신판매중개업 신고와 중개 서비스(카탈로그·주문 라우팅)를 본업으로 두는 사업 구조와 약관 정리가 필요합니다.
2. **자체 정산 시 다른 법령의 의무.** 판매대금 정산기한, 판매대금 별도관리(대규모유통업법·전자상거래법 쪽 개정 동향 및 규모 요건), 구매안전서비스(에스크로) 제공 의무, 부가가치세법상 통신판매중개자의 판매자별 거래자료 제출 의무를 확인해야 합니다.
3. **판매수수료 세금계산서 발행 주체와 시점**, 하위몰 매출 귀속(중개 구조이므로 판매대금은 하위몰 매출)도 정리가 필요합니다.

`DIRECT_BANK` 채널이라도 설계상 **정산 전용 계좌를 운영자금 계좌와 물리적으로 분리**합니다(`SETTLEMENT_BANK` ↔ `PLATFORM_OPERATING_CASH`). 의무 여부와 별개로 티메프 사태 이후 가맹점 신뢰의 기본 요건입니다.

## 3. 자금 흐름

```
                     ┌──────────── 구매자 결제 (플랫폼 MID, Toss 또는 이니시스) ───────────┐
                     ▼                                                                    │
 [Phase 1: PG_PAYOUT]                                                                     │
   PG ──(PG 정산: 결제액 − PG수수료)──▶ PG 지급대행 잔액 (플랫폼 명의, PG 보관)              │
                                          ├─(지급 지시: 하위몰 net)──▶ 하위몰 정산계좌        │
                                          └─(수수료 인출)──────────▶ 플랫폼 운영계좌          │
 [Phase 2: DIRECT_BANK]                                                                   │
   PG ──(PG 정산)──▶ 플랫폼 정산 전용 계좌 ─(펌뱅킹/오픈뱅킹 이체)─▶ 하위몰 정산계좌          │
                                          └─(수수료 인출)──────────▶ 플랫폼 운영계좌          │
```

포트(`packages/domain-settlement`):
```ts
interface PayoutGateway {
  registerPayee(profile: SettlementProfile): Promise<PayeeRef>;          // 서브몰 등록 / 예금주 실명조회
  requestPayout(cmd: PayoutCommand /* idempotencyKey = payout.id */): Promise<PayoutAck>;
  getPayout(externalId: string): Promise<PayoutStatus>;
  getBalance(): Promise<Money>;                                          // 지급 전 잔액 검증
}
// adapters: TossPayoutGateway, InicisPayoutGateway (PG_PAYOUT) / FirmBankingPayoutGateway (DIRECT_BANK)
```

## 4. 금액 계산 규칙

정산 분쟁은 대부분 1원 단위 차이에서 생기므로 규칙을 코드와 문서에 고정합니다.

| 항목 | 규칙 |
|---|---|
| 정산 대상액 `gross` | 하위몰 주문 `total_amount` (상품 + 배송비 − **하위몰 부담** 할인). 플랫폼 부담 쿠폰은 gross에서 차감하지 않고 플랫폼 비용으로 처리 |
| 판매수수료 `fee` | `floor(gross × fee_bps / 10000)`. 원 미만은 버림(하위몰에 유리하게, 분쟁 최소화) |
| 수수료 VAT `vat` | `floor(fee / 10)` |
| 하위몰 지급액 `net` | `gross − fee − vat` (DB CHECK 제약) |
| 부분 취소 | 환불분 수수료 = `원 수수료 − fee(남은 gross)`. 비율로 다시 계산하지 않고 **최종 잔여분 기준 차감**으로 처리해 누적 반올림 오차를 없앰 |
| 전액 취소 | 원 SALE 항목 금액을 **정확히 반대 부호로** 생성 |
| 수수료율 | `settlement_items.fee_bps_applied`에 스냅샷. 정책을 바꿔도 과거 정산을 재현할 수 있음 |
| 통합결제 배분 | `checkout_session_merchants`에서 하위몰별 금액이 확정되므로 PG 결제액 = Σ 하위몰 total (세션 생성 시 검증) |

## 5. 분개 규칙 (Journal)

`G`=주문 gross, `F`=판매수수료, `V`=수수료 VAT, `P`=PG수수료, `R`=환불액

| 사건 | tx_type | 차변 (DEBIT) | 대변 (CREDIT) | 시점 |
|---|---|---|---|---|
| 결제 승인 → 주문 생성 | `ORDER_SALE` | PG_RECEIVABLE `G` | MERCHANT_PAYABLE[하위몰] `G` | 결제 확정 트랜잭션 |
| 구매확정 (수수료 인식) | `PLATFORM_FEE` | MERCHANT_PAYABLE[하위몰] `F+V` | PLATFORM_FEE_REVENUE `F`, VAT_PAYABLE `V` | 구매확정 시 |
| 확정 전 취소 | `ORDER_REFUND` | MERCHANT_PAYABLE `R` | PG_RECEIVABLE `R` | PG 취소 성공 |
| 확정 후 환불(반품) | `ORDER_REFUND` | MERCHANT_PAYABLE `R−ΔF−ΔV`, PLATFORM_FEE_REVENUE `ΔF`, VAT_PAYABLE `ΔV` | PG_RECEIVABLE `R` | PG 취소 성공 |
| PG 수수료 확정 | `PG_FEE` | PG_FEE_EXPENSE `P` | PG_RECEIVABLE `P` | PG 정산 데이터 적재 |
| PG 정산금 입금 | `PG_SETTLEMENT_RECEIVED` | PAYOUT_BALANCE 또는 SETTLEMENT_BANK | PG_RECEIVABLE | 입금 확인 |
| 하위몰 지급 완료 | `PAYOUT` | MERCHANT_PAYABLE[하위몰] | PAYOUT_BALANCE 또는 SETTLEMENT_BANK | 지급 완료 콜백/조회 |
| 지급 반송(계좌오류) | `PAYOUT_FAILED_REVERSAL` | PAYOUT_BALANCE 또는 SETTLEMENT_BANK | MERCHANT_PAYABLE | 반송 확인 |
| 수수료 인출 | `PLATFORM_FEE_WITHDRAWAL` | PLATFORM_OPERATING_CASH | PAYOUT_BALANCE 또는 SETTLEMENT_BANK | 월 1회 |

불변식 (일일 검증 배치):
- `Σ MERCHANT_PAYABLE 대변잔액 ≤ PAYOUT_BALANCE + SETTLEMENT_BANK + PG_RECEIVABLE` → 위반 시 **지급 즉시 중단 + P1 알람** (하위몰에 줄 돈보다 보유 자금이 적은 상태)
- `PG_RECEIVABLE` 잔액 = PG가 아직 입금하지 않은 금액 (PG 정산 예정 데이터와 일치)

## 6. 정산 라이프사이클

```
settlement_items:  PENDING ──(구매확정)──▶ ELIGIBLE ──(정산배치 포함)──▶ INCLUDED ──(지급완료)──▶ PAID
                     │                         └──(분쟁/지급정지)──▶ HELD
                     └──(확정 전 전액취소)──▶ VOID

settlements:  DRAFT ─(검증)─▶ CONFIRMED ─▶ PAYOUT_REQUESTED ─▶ PAID
                                   │                     └─▶ PAYOUT_FAILED ─(계좌 수정 후 재요청)
                                   ├─ payout_amount ≤ 0 ─▶ CARRIED_OVER (다음 회차로 음수 이월)
                                   └─ payout_hold ───────▶ ON_HOLD
```

일일 정산 배치 (영업일 09:00 KST, `FOR UPDATE SKIP LOCKED`로 하위몰 단위 병렬 처리):
1. 자동 구매확정: `status = DELIVERED AND delivered_at < now() − 7d` → `PURCHASE_CONFIRMED`. SALE 항목은 `ELIGIBLE`(`settle_on` = 확정일 + D+N 영업일, 공휴일 캘린더 반영), `PLATFORM_FEE` 분개.
2. 하위몰별로 `ELIGIBLE AND settle_on ≤ today` 항목과 REFUND/ADJUSTMENT 항목을 합산하고, 직전 회차 음수 잔액을 반영한 뒤 `holdback_bps`만큼 보류합니다.
3. `settlements` 를 `DRAFT`로 만들고 검증합니다: Σ items = 집계값, 원장 MERCHANT_PAYABLE 잔액 ≥ payout_amount, 지급 가능 잔액(`getBalance`) ≥ 당일 지급 총액. 통과하면 `CONFIRMED`.
4. `payouts` 를 생성하고 `PayoutGateway.requestPayout`을 호출합니다(멱등키 = payout.id). 응답 타임아웃이 나도 **같은 멱등키로만 재조회·재시도**합니다.
5. 지급 완료 웹훅이나 조회 결과로 `PAID`를 반영하고, `PAYOUT` 분개와 하위몰 정산 명세(이메일·콘솔)를 발송합니다.

## 7. 대사 (Reconciliation)

| 대사 | 주기 | 대상 | 불일치 처리 |
|---|---|---|---|
| 거래 대사 | 일 | `pg_settlement_records` ↔ `payments`/`payment_cancellations` (거래키·금액) | MISMATCHED → 운영 큐. 우리 쪽에만 있음 = 웹훅·조회 누락, PG에만 있음 = **유령 결제**(즉시 조사) |
| 입금 대사 | 일 | PG 정산 예정액 ↔ 실제 입금(지급대행 잔액 조회 또는 계좌 거래내역) | 차액 알람 |
| 지급 대사 | 일 | `payouts` COMPLETED ↔ PG 지급내역 또는 은행 이체내역 | 반송 건 → `PAYOUT_FAILED_REVERSAL` |
| 원장 정합성 | 일 | Σ settlement_items(net, 미지급) = 하위몰별 MERCHANT_PAYABLE 잔액 | 불일치 시 해당 하위몰 지급 보류 |

## 8. 장애·예외 시나리오

| 시나리오 | 대응 |
|---|---|
| 하위몰 A 품절 거절 (통합결제 중 일부) | A 주문만 **부분취소**(`payment_cancellations`, amount = A.total). B 주문은 정상 진행. 결제수단별 부분취소 가능 여부를 어댑터에서 확인(가상계좌 환불계좌 등) |
| 지급 API 타임아웃 | 상태를 `PROCESSING`으로 두고 `getPayout` 조회로 확정. **새 멱등키로 재요청하는 것은 금지**(이중지급) |
| 지급 후 반품 → 하위몰 잔액 음수 | 다음 회차에서 상계(`carried_over_amount`). N일 이상 음수가 지속되면 채권 회수 프로세스로 넘기고, 신규 하위몰은 holdback으로 예방 |
| Toss 장애 | 결제 페이지에서 이니시스로 failover(플랫폼이 두 MID를 모두 보유하므로 가능). 지급대행은 결제와 같은 PG 잔액에서 나가므로 **PG별 잔액을 분리 관리** |
| 정산 배치 중단 | 하위몰 단위 트랜잭션 + `UNIQUE(merchant_id, settle_on)`으로 재실행해도 안전(멱등) |
| 운영자 수기 조정 | `ADJUSTMENT` 항목과 분개만 허용, 2인 승인, `audit_logs` 기록. 원장 UPDATE/DELETE는 트리거로 차단 |

## 9. 리뷰 포인트 / 남은 결정

1. **구매확정 기준**: 에이전트 경유 주문은 구매자가 우리 화면에 다시 오지 않을 가능성이 큽니다. 자동확정(배송완료 + 7일)이 사실상 기본이 되므로, 배송완료 신호(OMS 송장 → 택배사 추적 API)의 신뢰도가 정산 시점을 좌우합니다.
2. **PG별 잔액 분리**: Toss와 이니시스 지급대행 잔액은 서로 옮길 수 없습니다. 하위몰 지급액이 결제 PG별로 쪼개지므로 `payouts`를 PG별로 나누거나 `DIRECT_BANK`로 통합해야 합니다. Phase 1에서는 **결제 PG 기준으로 payout을 분할**하는 것을 권장합니다(정산 명세에도 반영).
3. **에이전트 채널 수수료**(`agent_channel_fee_bps`): 에이전트 플랫폼(OpenAI 등)이 수수료를 청구하면 하위몰에 전가할지 플랫폼이 부담할지 사업 결정이 필요합니다. 현재 원장에는 계정이 없으므로 결정 후 `AGENT_FEE_EXPENSE`를 추가합니다.
4. `DIRECT_BANK` 전환 시 펌뱅킹(은행 직접 계약)과 오픈뱅킹(이용기관 등록) 중 무엇을 쓸지, 이체 한도와 실명조회 비용도 정해야 합니다.
