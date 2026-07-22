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
- 한 번 연 마이크의 음성을 여러 스피커에 동시에 송출
- 스피커별 독립 SIP 통화 및 RTP 세션 관리
- 일부 스피커 연결 실패 시 연결된 스피커로 계속 송출
- 이벤트 로그 스트림 제공

## 설치 및 import

다른 Flutter 프로젝트에서 로컬 path dependency로 추가합니다.

```yaml
dependencies:
  simple_sip_client:
    path: ../simple_sip_client
```

그 다음 플러그인의 공개 API를 import합니다.

```dart
import 'package:simple_sip_client/simple_sip_client.dart';
```

## SIP 설정

단일 및 다중 송출 클라이언트는 동일한 `SipConfig`를 사용합니다.

```dart
const config = SipConfig(
  server: '192.168.x.x',
  port: 5060,
  username: 'username',
  password: 'password',
  domain: '192.168.y.y',
  microphoneGain: 2.5,
);
```

- `server`: SIP 서버의 IP 주소
- `port`: SIP 서버 포트. 일반적인 UDP SIP 포트는 `5060`입니다.
- `username`, `password`: SIP Digest 인증 계정
- `domain`: SIP URI에 사용할 도메인 또는 서버 주소
- `microphoneGain`: PCM 음성을 코덱으로 변환하기 전에 적용할 마이크 증폭값

## 단일 스피커 송출

지정 시간 동안만 마이크 음성을 송출하려면 `pageExtension`을 사용합니다.

```dart
import 'package:simple_sip_client/simple_sip_client.dart';

final client = SipPagingClient(
  config: SipConfig(
    server: '192.168.x.x',
    port: 5060,
    username: 'username',
    password: 'password',
    domain: '192.168.y.y',
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

## 여러 스피커 동시 송출

`SipMultiPagingClient`는 외부 마이크를 한 번만 열고 동일한 음성을 여러 스피커의 RTP 세션으로 동시에 전송합니다. 각 스피커는 별도의 SIP INVITE, RTP 주소, sequence, timestamp 및 SSRC를 사용합니다.

### 사용자가 중지할 때까지 송출

`startPageExtensions`에 송출할 스피커 목록을 전달합니다.

```dart
import 'package:simple_sip_client/simple_sip_client.dart';

final client = SipMultiPagingClient(config: config);

final eventSubscription = client.events.stream.listen((message) {
  print(message);
});

try {
  await client.register();

  final session = await client.startPageExtensions(
    targets: const [
      SipPagingTarget(label: 'speaker_1001', extension: '1001'),
      SipPagingTarget(label: 'speaker_1002', extension: '1002'),
      SipPagingTarget(label: 'speaker_1003', extension: '1003'),
      SipPagingTarget(label: 'speaker_1004', extension: '1004'),
    ],
    codec: Codec.pcma,
  );

  print('연결 성공: ${session.connectedTargets.length}');

  for (final failure in session.failedTargets) {
    print(
      '연결 실패: ${failure.target.label} '
      '(${failure.target.extension}) - ${failure.error}',
    );
  }

  // 사용자 Stop 버튼 등의 이벤트가 발생했을 때 호출합니다.
  await session.stop();
  await session.completed;

  await client.unregister();
} finally {
  await eventSubscription.cancel();
  await client.dispose();
}
```

`startPageExtensions`는 각 스피커 연결을 병렬로 시도합니다. 일부 스피커 연결에 실패해도 한 대 이상 연결되면 성공한 스피커로 송출을 시작합니다.

- `session.connectedTargets`: 연결되어 음성이 송출되는 대상
- `session.failedTargets`: 연결하지 못한 대상과 오류 정보
- `session.isActive`: 세션의 활성 여부
- `session.completed`: 마이크 송출과 모든 BYE 처리가 끝날 때 완료되는 Future
- `session.stop()`: 연결된 모든 스피커의 송출을 종료하고 BYE 전송

모든 스피커 연결에 실패하면 `startPageExtensions`가 `SipException`을 발생시킵니다.

### 지정 시간 동안 송출

정해진 시간이 지나면 자동으로 모든 스피커 송출을 종료하려면 `pageExtensions`를 사용합니다.

```dart
final client = SipMultiPagingClient(config: config);

try {
  await client.register();

  await client.pageExtensions(
    targets: const [
      SipPagingTarget(label: 'speaker_1001', extension: '1001'),
      SipPagingTarget(label: 'speaker_1002', extension: '1002'),
    ],
    codec: Codec.pcma,
    duration: const Duration(seconds: 10),
  );

  await client.unregister();
} finally {
  await client.dispose();
}
```

### 다중 송출 사용 시 주의사항

- `targets`에는 한 개 이상의 대상이 필요합니다.
- 한 번의 호출에서 동일한 내선 번호를 중복 지정할 수 없습니다.
- `SipMultiPagingClient` 인스턴스 하나에는 동시에 하나의 다중 송출 세션만 실행할 수 있습니다.
- 송출 중에는 같은 클라이언트에서 새로운 `startPageExtensions`를 호출하지 말고 기존 세션을 먼저 종료해야 합니다.
- SIP 서버와 계정이 여러 동시 INVITE를 허용해야 합니다. 서버가 동시 통화를 제한하면 일부 대상이 `Busy` 등의 응답으로 실패할 수 있습니다.
- IP 스피커는 INVITE를 자동 응답하고 PCMA 또는 PCMU 수신을 지원하도록 설정되어야 합니다.
- 현재 구현은 IPv4 및 UDP SIP/RTP를 사용합니다.
- 앱 종료 전 활성 세션을 중지하고 `dispose()`를 호출해야 마이크와 UDP 소켓이 정리됩니다.

## 이벤트 로그

두 클라이언트 모두 `events` 스트림으로 REGISTER, INVITE, 연결, 송출 및 종료 상태를 전달합니다.

```dart
final subscription = client.events.stream.listen((message) {
  print(message);
});

// 화면 또는 클라이언트를 종료할 때
await subscription.cancel();
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
- 우측 상단의 `Multi` 버튼을 누르면 여러 스피커 동시 송출 예제로 이동합니다.
- 다중 송출 화면에서 스피커를 복수 선택하고 한 번에 송출하거나 중지할 수 있습니다.
- 다중 송출 화면의 로그에서 스피커별 연결 성공 및 실패를 확인할 수 있습니다.

예제 앱의 SIP 서버와 스피커 내선 설정은 `example/lib/config/sip_settings.dart`에서 수정할 수 있습니다.


