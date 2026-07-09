# simple_sip_client

Windows 클라이언트에서 Asterisk SIP 서버를 통해 스피커 페이징을 수행하기 위한 Flutter 플러그인입니다.

이 플러그인은 범용 SIP UA 라이브러리 대신, 현장에서 필요한 페이징 흐름에 집중합니다. SIP 등록, 인증된 INVITE, PCMA/PCMU 기반 send-only RTP 마이크 스트리밍, BYE 종료 흐름만 단순하고 예측 가능하게 처리합니다.

## 지원 플랫폼

- Windows

## 주요 기능

- SIP REGISTER / UNREGISTER
- Digest 인증 처리
- SIP INVITE / ACK / BYE 흐름
- 마이크 입력을 RTP로 전송
- PCMA, PCMU 코덱 지원
- 지정 시간 동안 송출하는 페이징
- 사용자가 중지할 때까지 계속 송출하는 페이징 세션
- 이벤트 로그 스트림 제공

## 사용 예시

지정 시간 동안만 마이크 음성을 송출하려면 `pageExtension`을 사용합니다.

```dart
import 'package:simple_sip_client/simple_sip_client.dart';

final client = SipPagingClient(
  config: SipConfig(
    server: '192.168.5.100',
    port: 5060,
    username: 'control-pc-1',
    password: 'password',
    domain: '192.168.5.100',
  ),
);

await client.register();
await client.pageExtension(
  label: 'speaker_1001',
  extension: '1001',
  codec: Codec.pcma,
  duration: const Duration(seconds: 5),
);
await client.unregister();
await client.dispose();
```

사용자가 직접 중지할 때까지 계속 송출하려면 `startPageExtension`으로 세션을 시작하고, 필요한 시점에 `stop`을 호출합니다.

```dart
final session = await client.startPageExtension(
  label: 'speaker_1001',
  extension: '1001',
  codec: Codec.pcma,
);

await session.stop();
```

## 예제 앱 실행

예제 앱은 `example/` 디렉터리에 있습니다.

```powershell
cd example
flutter run -d windows
```

앱을 실행하면 기본 화면으로 지속 송출 예제가 열립니다.

- 앱 시작 시 자동으로 SIP 서버에 REGISTER를 보냅니다.
- 스피커 버튼을 누르면 선택한 내선으로 마이크 음성을 계속 송출합니다.
- `Stop` 버튼을 누르면 BYE를 보내고 송출을 종료합니다.
- `Unregister` 버튼으로 SIP 등록을 해제합니다.
- 우측 상단의 `Timed` 버튼을 누르면 기존 지정 시간 송출 예제로 이동합니다.

예제 앱의 SIP 서버와 스피커 내선 설정은 `example/lib/config/sip_settings.dart`에서 수정할 수 있습니다.

## 다른 프로젝트에서 사용하기

로컬 path dependency로 추가해서 사용할 수 있습니다.

```yaml
dependencies:
  simple_sip_client:
    path: ../simple_sip_client
```

그 다음 필요한 곳에서 다음처럼 import합니다.

```dart
import 'package:simple_sip_client/simple_sip_client.dart';
```


