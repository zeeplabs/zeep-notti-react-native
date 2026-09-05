import { Text, View, StyleSheet } from 'react-native';

// SPEC_DEVIATION: T4 removed the scaffolded `multiply` placeholder from the
// SDK's public surface (replaced by the real v1 Spec in NativeNuntis.ts).
// This example screen is a placeholder until T18 wires it up against the
// real facade (Nuntis.initialize/requestPermission/etc.) once T16 ships it.
export default function App() {
  return (
    <View style={styles.container}>
      <Text>react-native-nuntis example</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },
});
