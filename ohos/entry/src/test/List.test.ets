import localUnitTest from './LocalUnit.test';
import virtualPadLayoutTest from './VirtualPadLayout.test';

export default function testsuite() {
  localUnitTest();
  virtualPadLayoutTest();
}