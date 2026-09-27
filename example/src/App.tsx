import { useEffect } from 'react';
import { Button, StyleSheet, Text, View } from 'react-native';
import { Notti } from 'react-native-notti';

// Manual smoke-test wiring (T18) - placeholders only, never real
// credentials. Replace with a real App's appId/clientKey/baseUrl from a
// running Notti instance to exercise the SDK end-to-end; see README.md's
// "Manual smoke testing" section for the full checklist (T19).
const NOTTI_APP_ID = 'REPLACE_WITH_YOUR_APP_ID';
const NOTTI_CLIENT_KEY = 'REPLACE_WITH_YOUR_CLIENT_KEY';
const NOTTI_BASE_URL = 'https://your-notti-instance.example.com';

export default function App() {
  useEffect(() => {
    Notti.initialize(NOTTI_APP_ID, NOTTI_CLIENT_KEY, {
      baseUrl: NOTTI_BASE_URL,
    });

    // Cold start only: a tap that launched the process happens before this
    // effect runs, so `notificationClicked` below never fires for it. Pull it
    // once here instead - warm clicks (app already running) keep using the
    // event listener.
    Notti.getInitialNotificationClick().then((payload) => {
      if (payload) {
        console.log('Notti getInitialNotificationClick', payload);
      }
    });

    const received = Notti.addEventListener(
      'notificationReceived',
      (payload) => {
        console.log('Notti notificationReceived', payload);
      }
    );
    const clicked = Notti.addEventListener('notificationClicked', (payload) => {
      console.log('Notti notificationClicked', payload);
    });

    // Subscribe before reading the current value: registration can complete
    // between the two calls, and the event does not replay a change it
    // already fired before this listener existed.
    const deviceIdChanged = Notti.addEventListener(
      'deviceIdChanged',
      (deviceId) => {
        console.log('Notti deviceIdChanged', deviceId);
      }
    );

    // `null` until registration assigns one - cached locally, no network
    // round-trip. Persist whichever of the two you get first alongside your
    // user record.
    console.log('Notti getDeviceId', Notti.getDeviceId());

    return () => {
      received.remove();
      clicked.remove();
      deviceIdChanged.remove();
    };
  }, []);

  return (
    <View style={styles.container}>
      <Text>react-native-notti example</Text>
      <Button
        title="Request permission"
        onPress={() => {
          Notti.requestPermission().then((granted) =>
            console.log('Notti requestPermission granted:', granted)
          );
        }}
      />
      <Button
        title="Add tags"
        onPress={() =>
          Notti.User.addTags({ plan: 'vip', source: 'example-app' })
        }
      />
      <Button title="Remove tag" onPress={() => Notti.User.removeTag('plan')} />
      <Button title="Login" onPress={() => Notti.login('example-user-1')} />
      <Button title="Logout" onPress={() => Notti.logout()} />
      <Button
        title="Enable subscription"
        onPress={() => Notti.setSubscription(true)}
      />
      <Button
        title="Disable subscription"
        onPress={() => Notti.setSubscription(false)}
      />
      <Button
        title="Log device id"
        onPress={() => console.log('Notti getDeviceId', Notti.getDeviceId())}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
  },
});
