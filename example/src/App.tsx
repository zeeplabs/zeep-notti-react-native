import { useEffect } from 'react';
import { Button, StyleSheet, Text, View } from 'react-native';
import { Nuntis } from 'react-native-nuntis';

// Manual smoke-test wiring (T18) - placeholders only, never real
// credentials. Replace with a real App's appId/clientKey/baseUrl from a
// running Nuntis instance to exercise the SDK end-to-end; see README.md's
// "Manual smoke testing" section for the full checklist (T19).
const NUNTIS_APP_ID = 'REPLACE_WITH_YOUR_APP_ID';
const NUNTIS_CLIENT_KEY = 'REPLACE_WITH_YOUR_CLIENT_KEY';
const NUNTIS_BASE_URL = 'https://your-nuntis-instance.example.com';

export default function App() {
  useEffect(() => {
    Nuntis.initialize(NUNTIS_APP_ID, NUNTIS_CLIENT_KEY, NUNTIS_BASE_URL);

    const received = Nuntis.addEventListener(
      'notificationReceived',
      (payload) => {
        console.log('Nuntis notificationReceived', payload);
      }
    );
    const clicked = Nuntis.addEventListener(
      'notificationClicked',
      (payload) => {
        console.log('Nuntis notificationClicked', payload);
      }
    );

    return () => {
      received.remove();
      clicked.remove();
    };
  }, []);

  return (
    <View style={styles.container}>
      <Text>react-native-nuntis example</Text>
      <Button
        title="Request permission"
        onPress={() => {
          Nuntis.requestPermission().then((granted) =>
            console.log('Nuntis requestPermission granted:', granted)
          );
        }}
      />
      <Button
        title="Add tags"
        onPress={() =>
          Nuntis.User.addTags({ plan: 'vip', source: 'example-app' })
        }
      />
      <Button
        title="Remove tag"
        onPress={() => Nuntis.User.removeTag('plan')}
      />
      <Button title="Login" onPress={() => Nuntis.login('example-user-1')} />
      <Button title="Logout" onPress={() => Nuntis.logout()} />
      <Button
        title="Enable subscription"
        onPress={() => Nuntis.setSubscription(true)}
      />
      <Button
        title="Disable subscription"
        onPress={() => Nuntis.setSubscription(false)}
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
