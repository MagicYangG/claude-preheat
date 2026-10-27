# claude-preheat

[English](README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | **한국어**

https://github.com/user-attachments/assets/b0614c1a-fe78-4464-a11e-aaeb1794829e

Windows 또는 macOS에서 Claude Code CLI로 작업하는 Claude 구독 사용자를 위한 도구입니다. 5시간 사용량 윈도우는 활성 윈도우가 없을 때 보낸 첫 메시지에 앵커됩니다 — 예약된 아주 작은 핑으로 원하는 시각에 윈도우를 앵커해, 실제 작업이 5시간 윈도우 두 개에 걸쳐 이어지게 합니다. 제공 기능:

1. 주 단위 정기 예열
2. 일회성 예열
3. **Codex(beta)**: 같은 예열을 OpenAI Codex에도 쓸 수 있습니다. [Codex (beta)](#codex-beta) 참고

## 웹 패널

로컬 주소: `localhost:7878` (영어/중국어, 헤더에서 원클릭 전환)

모듈: 실시간 쿼터 스트립(5시간 + 주간, 정확한 리셋 시각 포함 — `preheat statusline on` 을 한 번 실행하면 값이 들어옵니다) / 주간 리셋 시각 편집기(`schedule.json` 에 기록하고 바로 적용) / 일회성 예열 / 최근 7일 윈도우 활용률 라인(내부적으로 `preheat learn`) / 페이지 상단 Claude | Codex 전환(Codex는 beta)

![panel](docs/panel.png)

## 빠른 시작

**요구 사항**: Windows 10/11 또는 macOS 13+ ([macOS 가이드](docs/MAC-BETA.md) 참고); [Claude Code CLI](https://code.claude.com/docs) 설치·로그인; Claude 구독; PowerShell 7 (pwsh); 관리자 권한 불필요; Codex(beta)만 예열한다면 Claude Code와 Claude 구독은 필요 없음, [Codex (beta)](#codex-beta) 참고

**추천: 아래 내용을 Claude Code(또는 다른 AI 코딩 도구)에 붙여 넣어 설치를 맡기세요:**

```text
https://github.com/MagicYangG/claude-preheat 를 클론하고 설치해 줘:
1. git clone 후 저장소 디렉터리에서 install.ps1 실행
2. 매주 윈도우가 리셋되길 원하는 시각을 나에게 물어 schedule.json에 기록
   (reset에는 목표 리셋 시각을 적는다. 예열 시각은 자동으로 reset − 5시간)
3. ./test.ps1 을 실행해 전체 케이스 통과 확인
4. preheat apply 실행 후 preheat status 출력을 보여줘
install.ps1 과 preheat apply 가 만드는 것 외에는 아무것도 등록하거나 변경하지 말 것.
```

설치가 끝나면 브라우저에서 `http://localhost:7878` 을 열어 패널로 조작하면 됩니다.

**수동 설치는 3단계**: `git clone` → `./install.ps1` → 새 터미널에서 `preheat apply`. 전체 명령은 [명령 레퍼런스](#명령-레퍼런스)를 참고하세요.

## 주의 사항

1. **Claude Code CLI 필요**(Codex만 쓴다면 불필요): 예열은 CLI를 통해 실행되는 아주 작은 headless 프롬프트입니다
2. **핑 1회 비용**: 짧은 `haiku` 프롬프트 1건 — Claude Code 자체 시스템 프롬프트까지 합치면 약 4만 input 토큰(API 가격 기준 약 $0.04)입니다. 5시간 윈도우와 주간 윈도우 모두에 집계되므로, 예열은 저렴하지만 공짜는 아닙니다. 이미 활성인 윈도우에 핑을 보내도 앵커는 움직이지 않습니다. 예약된 예열이 실행 중인 윈도우에 떨어지면, 그 윈도우가 만료되는 분에 후속 핑을 한 번만 예약합니다(그날은 핑이 두 번이 됩니다). 윈도우당 최대 한 번이며, 다음 예약 예열이 먼저 오면 예약하지 않습니다. `schedule.json` 에 `"chase": false` 를 넣으면 끕니다. 패널에서 직접 만들지 않은 일회성 작업은 이 후속 예열입니다. 주간 윈도우는 이 도구가 관리하지 않습니다.
3. **절전에서 깨우기**: 예약된 실행이 PC를 깨우려면 현재 전원 관리 옵션에서 절전 해제 타이머가 켜져 있어야 합니다 — 꺼져 있으면 `preheat status` 가 경고합니다 (Windows의 메커니즘입니다. launchd는 잠자기 중인 Mac을 깨울 수 없습니다 — [macOS 가이드](docs/MAC-BETA.md) 참고). 후속 핑은 잠자는 PC를 깨우지 않습니다. 그 분에 기기가 절전 중이면 건너뜁니다.
4. **윈도우는 계정 단위입니다**: claude.ai, Claude 데스크톱, Claude Code의 사용량은 하나의 풀을 공유하므로, 예열은 모든 서피스의 윈도우에 적용됩니다 — CLI는 점화 바늘일 뿐입니다
5. **예열이 실행되는 때와 안 되는 때(Windows)**: 작업은 로그인 상태에서만 실행됩니다(잠금 화면은 괜찮지만, 로그아웃 상태면 그 예열은 건너뜁니다). 이제 배터리 사용 중에도 실행됩니다. 이 변경 전에 설치했다면 `preheat apply` 를 한 번 더 실행해 등록된 작업에 새 설정을 반영하세요.
6. **`preheat apply` 이후 저장소 디렉터리를 옮기거나 이름을 바꾸지 마세요**: 예약된 작업, launchd plist, 프로필 함수 모두 절대 경로를 담고 있습니다. 옮겼다면 `install.ps1` 과 `preheat apply` 를 다시 실행하세요 — `preheat status` 가 스크립트 경로가 더 이상 존재하지 않는 작업을 표시해 줍니다.

## Codex (beta)

Codex 지원은 현재 beta입니다. 같은 `schedule.json`, 패널, 예약 작업으로 OpenAI Codex의 5시간 윈도우도 예열할 수 있습니다. 양쪽은 각자 따로 예약되며 서로 영향을 주지 않습니다. 베타 테스트 방법과 증거를 보내는 법은 [Codex beta 가이드](docs/CODEX-BETA.md)를 참고하세요.

**요구 사항**: [Codex CLI](https://learn.chatgpt.com/docs/codex/cli) 또는 Codex 데스크톱 앱을 설치하고 ChatGPT 계정으로 로그인해 두어야 합니다(API 키 로그인에는 5시간 윈도우가 없으므로 핑을 보내지 않습니다). Plus 등 5시간 윈도우가 있는 요금제에서 쓸 수 있습니다. Free / Go / Pro는 5시간 윈도우를 읽지 못하면 건너뛰고 사용량을 쓰지 않습니다(Go는 실제 계정에서 확인한 결과 30일 윈도우만 있습니다). 그 밖의 요금제에서 읽지 못하면 그대로 핑을 보내고 사용량을 씁니다. Codex만 예열한다면 Claude Code와 Claude 구독은 필요 없습니다.

**켜기**: AI 코딩 도구에 맡기면 간단합니다("Codex 예열을 평일 15:00 리셋으로 설정해 줘"라고만 말하면 됩니다). 패널에서는 페이지 상단에서 Codex 탭으로 바꾸고 시각을 골라 적용하세요(Codex 쪽만 바뀝니다). 직접 편집한다면 저장소 디렉터리의 `schedule.json`(install.ps1이 생성)에 `codex` 키를 추가합니다. 기존 `rules`, `proxy` 와 같은 수준에 두고, 바로 앞 항목 끝에 쉼표를 붙이세요(예열 시각은 마찬가지로 reset − 5h):

```json
"codex": { "rules": [ { "days": ["Mon", "Tue", "Wed", "Thu", "Fri"], "reset": "15:00" } ], "chase": true }
```
그다음 `preheat apply -Provider codex` 를 실행합니다. Codex만 쓴다면 최상위 `rules` 를 `[]` 로 두거나 항상 `-Provider codex` 를 붙이세요. 그렇지 않으면 일반 `preheat apply` 가 claude를 찾다가 없으면 오류를 냅니다.

**확인**: `preheat status -Codex` 를 실행합니다(읽기만 하며 사용량을 쓰지 않습니다). 요금제, 5시간 윈도우, 등록된 `ClaudePreheat-Codex-*` 작업이 보이면 됩니다. 바로 시험해 보려면 `preheat +2m -Codex`.

**매 예열마다**(핑을 보낼 수도 있는 예약 시각):
1. 먼저 무료로 사용량을 읽습니다. 윈도우가 실행 중이면 핑을 보내지 않고, 만료 후 약 2분 뒤에 후속 예열을 한 번만 예약합니다(`chase` 와 같은 규칙)
2. 윈도우가 비어 있을 때만 아주 작은 핑을 보냅니다. 사용량 읽기 자체가 실패하면(네트워크, 프록시, 시간 초과) 그래도 핑을 보냅니다
3. 2회 연속 핑을 보냈는데도 윈도우가 시작되지 않으면 이후 예열은 핑을 멈추고 한 번만 알립니다. `preheat apply` 를 다시 실행할 때까지 멈춘 상태로 남습니다

**비용**: Codex 핑은 매번 실제 사용량을 쓰며, 5시간 한도와 주간 한도 모두에 집계됩니다. 무료인 것은 사용량 읽기뿐입니다.

**주의**:
1. 데스크톱 앱만 설치해도 됩니다: 매 예열마다 codex 실행 파일을 새로 찾습니다. 찾지 못하면 Windows에서는 사용자 환경 변수 `PREHEAT_CODEX_EXE` 에 전체 경로를 지정하고, macOS에서는 `preheat apply` 를 실행하는 터미널의 PATH에 codex 폴더를 추가하세요
2. `CODEX_HOME` 을 바꿔 두었다면 그 값이 설정된 터미널에서 `preheat apply` 를 한 번 실행하세요. `codex.home` 에 저장됩니다. `proxy` 는 양쪽이 공유합니다. 양쪽 다 예약했다면 Windows가 하룻밤에 PC를 두 번 깨울 수 있습니다
3. 그만두기: `preheat off -Codex` 는 Codex 작업만 지우지만, `codex` 섹션이 남아 있으면 다음 일반 `preheat apply` 때 다시 등록됩니다. 완전히 끄려면 `codex` 섹션을 지우세요(섹션 없음 = Codex 꺼짐)

## 릴레이(relay)는 어디로 갔나요?

v0.2.0 에는 윈도우 간 자동 재개("릴레이")가 있었습니다. Claude Code v2.1.234 부터 CLI 가 한도 리셋 시 자동 이어가기를 기본 제공하므로(기본 켜짐, `/config` 의 "Continue automatically at usage limit"), v0.3.0 에서 릴레이를 은퇴시켰습니다. 릴레이가 들어 있는 마지막 릴리스는 [v0.2.0](https://github.com/MagicYangG/claude-preheat/releases/tag/v0.2.0) 태그에 남아 있습니다. 네이티브 기능이 하지 않는 일 — 자리에 앉기 전에 윈도우를 미리 시작해 두는 것 — 이 바로 preheat 가 하는 일입니다.

## 명령 레퍼런스

평소에는 패널이면 충분합니다. 아래는 터미널·스크립트용입니다.

```powershell
preheat apply           # schedule.json 기준으로 매주 예열 작업 등록(수정 후 재실행하면 반영)
preheat status          # 로컬 활동 + 등록 작업 + 최근 로그
preheat reset 20:00     # 일회성: 윈도우를 20:00에 리셋(15:00 자동 예열)
preheat at 15:00        # 일회성: 15:00에 예열
preheat +2h             # 일회성: 2시간 후 예열
preheat learn           # 최근 30일 리듬으로 예열 시각 제안 + 윈도우 활용률 리포트(learn auto = 기록+적용)
                         # (집계 대상은 본인이 직접 보낸 프롬프트의 자연스러운 리듬뿐. preheat 핑은 집계되지 않습니다)
preheat statusline on   # statusline 투명 탭으로 정확한 리셋 시각을 패널 쿼터 스트립에 공급(순수 패스스루; off = 복원)
preheat off             # 예열 작업 전체 제거
preheat status -Codex   # Codex 사용량을 현장에서 읽기: 계정, 요금제, 5시간/주간 윈도우, 리셋 시각이 뒤로 밀렸는지, 최근 예열
preheat report -Codex   # 마스킹된 Codex 예열 증거 출력(issue에 붙여 넣기용)
preheat apply -Provider codex  # Codex 쪽만 등록(지정 없음 = 양쪽)
preheat at 10:00 -Codex # 일회성 Codex 예열. reset / +2h 에도 -Codex 를 붙입니다
preheat off -Codex      # Codex 예열 작업만 제거(-Codex 없음 = 양쪽 제거)
claude-panel            # 로컬 웹 패널 열기
```

`schedule.json` 의 `reset` 은 **목표 리셋 시각**이며, 예열 시각은 자동으로 reset − 5h. `proxy` 를 비우면 프록시를 쓰지 않습니다.

## 제거

```powershell
preheat off             # 예열 작업 전체 제거
preheat statusline off  # 원래 statusline 복원(투명 탭을 켰던 경우)
```

그 후 PowerShell 프로필(`$PROFILE.CurrentUserAllHosts`)에서 `# >>> claude-preheat functions >>>` 부터
`# <<< claude-preheat functions <<<` 사이의 줄을 지우고(예전 버전으로 설치했다면
`claude-limit-relay` 마커일 수 있습니다), 저장소 디렉터리를 삭제하면 됩니다.

Codex 런타임 파일(`state-ratelimits-codex.json`, `firepit-codex/`, `.fire-codex.lock`)은 모두 저장소 디렉터리 안에 있어 디렉터리와 함께 지워집니다. `PREHEAT_CODEX_EXE` 를 설정했다면 그것도 지우세요. preheat 는 Codex 자체 로그인에는 손대지 않습니다.
