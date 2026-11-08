import { Component, type ErrorInfo, type ReactNode } from 'react';
import { useTranslation } from 'react-i18next';

interface Props {
  /** Layout node type and id — named in the message and the console entry. */
  nodeLabel: string;
  /** A new value (other dataset, other node) gives the element a fresh try. */
  resetKey: unknown;
  children: ReactNode;
}

interface State {
  error: Error | null;
  /** The resetKey of the last render — a different one clears the error. */
  seenKey: unknown;
}

/**
 * Catches a render error of ONE dashboard element. Without it a single failing
 * primitive unmounts the whole React tree and leaves an empty window; with it
 * the element shows a short notice and the rest of the dashboard stays usable.
 * New data or a changed node (`resetKey`) renders the element again.
 */
export class PrimitiveErrorBoundary extends Component<Props, State> {
  constructor(props: Props) {
    super(props);
    this.state = { error: null, seenKey: props.resetKey };
  }

  static getDerivedStateFromError(error: Error): Partial<State> {
    return { error };
  }

  static getDerivedStateFromProps(props: Props, state: State): Partial<State> | null {
    // New inputs since the last render: the element gets a fresh try.
    if (props.resetKey !== state.seenKey) return { error: null, seenKey: props.resetKey };
    return null;
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error(`Dashboard element ${this.props.nodeLabel} failed to render`, error, info.componentStack);
  }

  render() {
    if (this.state.error) {
      return <PrimitiveErrorNotice nodeLabel={this.props.nodeLabel} message={this.state.error.message} />;
    }
    return this.props.children;
  }
}

function PrimitiveErrorNotice({ nodeLabel, message }: { nodeLabel: string; message: string }) {
  const { t } = useTranslation('dashboard');
  return (
    <div className="dash-primitive-error" role="alert" title={nodeLabel}>
      {t('renderer.primitiveError', { message, defaultValue: 'This element could not be displayed: {{message}}' })}
    </div>
  );
}
