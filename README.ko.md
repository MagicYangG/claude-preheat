# claude-preheat

[English](README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | **한국어**

![claude-preheat 데모](docs/demo.webp)

Windows 또는 macOS에서 Claude Code CLI로 작업하는 Claude 구독 사용자를 위한 도구입니다. 5시간 사용량 윈도우는 활성 윈도우가 없을 때 보낸 첫 메시지에 앵커됩니다 — 예약된 아주 작은 핑으로 원하는 시각에 윈도우를 앵커해, 실제 작업이 5시간 윈도우 두 개에 걸쳐 이어지게 합니다. 제공 기능은 두 가지:

1. 주 단위 정기 예열
2. 일회성 예열

## 웹 패널

로컬 주소: `localhost:7878` (영어/중국어, 헤더에서 원클릭 전환)

모듈: 실시간 쿼터 스트립(5시간 + 주간, 정확한 리셋 시각 포함 — `preheat statusline on` 을 한 번 실행하면 값이 들어옵니다) / 주간 리셋 시각 편집기(`schedule.json` 에 기록하고 바로 적용) / 일회성 예열 / 최근 7일 윈도우 활용률 라인(내부적으로 `preheat learn`)

![panel](docs/panel.png)

## 빠른 시작

**요구 사항**: Windows 10/11 또는 macOS 13+ ([macOS 가이드](docs/MAC-BETA.md) 참고); [Claude Code CLI](https://code.claude.com/docs) 설치·로그인; Claude 구독; PowerShell 7 (pwsh); 관리자 권한 불필요

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

1. **Claude Code CLI 필요**: 예열은 CLI를 통해 실행되는 아주 작은 headless 프롬프트입니다
2. **핑 1회 비용**: 짧은 `haiku` 프롬프트 1건 — Claude Code 자체 시스템 프롬프트까지 합치면 약 4만 input 토큰(API 가격 기준 약 $0.04)입니다. 5시간 윈도우와 주간 윈도우 모두에 집계되므로, 예열은 저렴하지만 공짜는 아닙니다. 이미 활성인 윈도우에 핑을 보내는 것은 무해한 no-op으로, 앵커는 움직이지 않습니다. 주간 윈도우는 이 도구가 관리하지 않습니다.
3. **절전에서 깨우기**: 예약된 실행이 PC를 깨우려면 현재 전원 관리 옵션에서 절전 해제 타이머가 켜져 있어야 합니다 — 꺼져 있으면 `preheat status` 가 경고합니다 (Windows의 메커니즘입니다. launchd는 잠자기 중인 Mac을 깨울 수 없습니다 — [macOS 가이드](docs/MAC-BETA.md) 참고)
4. **윈도우는 계정 단위입니다**: claude.ai, Claude 데스크톱, Claude Code의 사용량은 하나의 풀을 공유하므로, 예열은 모든 서피스의 윈도우에 적용됩니다 — CLI는 점화 바늘일 뿐입니다
5. **예열이 실행되는 때와 안 되는 때(Windows)**: 작업은 로그인 상태에서만 실행됩니다(잠금 화면은 괜찮지만, 로그아웃 상태면 그 예열은 건너뜁니다). 이제 배터리 사용 중에도 실행됩니다. 이 변경 전에 설치했다면 `preheat apply` 를 한 번 더 실행해 등록된 작업에 새 설정을 반영하세요.
6. **`preheat apply` 이후 저장소 디렉터리를 옮기거나 이름을 바꾸지 마세요**: 예약된 작업, launchd plist, 프로필 함수 모두 절대 경로를 담고 있습니다. 옮겼다면 `install.ps1` 과 `preheat apply` 를 다시 실행하세요 — `preheat status` 가 스크립트 경로가 더 이상 존재하지 않는 작업을 표시해 줍니다.

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
